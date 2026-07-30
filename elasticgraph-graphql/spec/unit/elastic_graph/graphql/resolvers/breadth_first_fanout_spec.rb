# Copyright 2024 - 2026 Block, Inc.
#
# Use of this source code is governed by an MIT-style
# license that can be found in the LICENSE file or at
# https://opensource.org/licenses/MIT.
#
# frozen_string_literal: true

require "elastic_graph/graphql/resolvers/breadth_first_fanout"

module ElasticGraph
  class GraphQL
    module Resolvers
      RSpec.describe BreadthFirstFanout do
        describe ".needed_for?" do
          it "returns false for the built-in resolvers that never query the datastore" do
            expect(BreadthFirstFanout::NON_DATASTORE_RESOLVER_NAMES).to all satisfy { |name|
              !BreadthFirstFanout.needed_for?(name)
            }
          end

          it "returns true for any other resolver, so that an unrecognized one is deferred by default" do
            expect(BreadthFirstFanout.needed_for?(:list_records)).to be true
            expect(BreadthFirstFanout.needed_for?(:some_extension_resolver)).to be true
          end
        end

        describe ".apply" do
          it "registers `Deferred` as a lazy class so the engine knows how to resolve placeholders" do
            graphql_schema = Class.new(::GraphQL::Schema)

            BreadthFirstFanout.apply(graphql_schema)

            expect(graphql_schema.lazy_method_name(BreadthFirstFanout::Deferred.new(nil))).to eq :resolve
          end
        end

        describe ".wrap" do
          it "defers resolution instead of resolving inline" do
            resolved_objects = []

            with_dataloading do |context|
              wrapped = BreadthFirstFanout.wrap(->(object, args, ctx) { resolved_objects << object })

              [1, 2, 3].map { |object| wrapped.call(object, {}, context) }

              # Nothing has been resolved yet: that is what lets the keys from sibling objects
              # accumulate into one batch before any of them blocks on the dataloader.
              expect(resolved_objects).to be_empty
            end
          end

          it "resolves all the deferred calls together, in one batch, in the order they were wrapped" do
            batch_sizes = []
            allow_any_instance_of(BreadthFirstFanout::Source).to receive(:fetch).and_wrap_original do |fetch, slots|
              batch_sizes << slots.size
              fetch.call(slots)
            end

            resolved = with_dataloading do |context|
              wrapped = BreadthFirstFanout.wrap(->(object, args, ctx) { "resolved-#{object}" })

              [1, 2, 3].map { |object| wrapped.call(object, {}, context) }.map(&:resolve)
            end

            expect(resolved).to eq ["resolved-1", "resolved-2", "resolved-3"]
            expect(batch_sizes).to eq [3]
          end

          it "passes the object, args, and context through to the wrapped resolver" do
            received = nil
            args = {"first" => 3}

            with_dataloading do |context|
              wrapped = BreadthFirstFanout.wrap(->(object, resolver_args, ctx) do
                received = {object: object, args: resolver_args, context: ctx}
                nil
              end)

              wrapped.call("the-object", args, context).resolve
            end

            expect(received[:object]).to eq "the-object"
            expect(received[:args]).to eq args
            expect(received[:context]).to be_a ::GraphQL::Query::Context
          end

          it "isolates an `ExecutionError` to the resolver that raised it, leaving its siblings resolved" do
            resolved = with_dataloading do |context|
              wrapped = BreadthFirstFanout.wrap(->(object, args, ctx) do
                raise ::GraphQL::ExecutionError, "boom" if object == 2
                "resolved-#{object}"
              end)

              [1, 2, 3].map { |object| wrapped.call(object, {}, context) }.map do |deferred|
                deferred.resolve
              rescue ::GraphQL::ExecutionError => e
                e
              end
            end

            expect(resolved[0]).to eq "resolved-1"
            expect(resolved[1]).to be_a(::GraphQL::ExecutionError).and have_attributes(message: "boom")
            expect(resolved[2]).to eq "resolved-3"
          end

          it "allows a non-`ExecutionError` to propagate, since it indicates a bug rather than a field error" do
            expect {
              with_dataloading do |context|
                wrapped = BreadthFirstFanout.wrap(->(object, args, ctx) { raise ArgumentError, "not a field error" })
                wrapped.call(1, {}, context).resolve
              end
            }.to raise_error ArgumentError, "not a field error"
          end
        end

        def with_dataloading
          ::GraphQL::Dataloader.with_dataloading do |dataloader|
            yield ::GraphQL::Query::Context.new(
              query: instance_double(::GraphQL::Query, fingerprint: "BreadthFirstFanoutQuery/test"),
              schema: Class.new(::GraphQL::Schema),
              values: {dataloader: dataloader}
            )
          end
        end
      end
    end
  end
end
