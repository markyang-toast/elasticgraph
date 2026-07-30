# Copyright 2024 - 2026 Block, Inc.
#
# Use of this source code is governed by an MIT-style
# license that can be found in the LICENSE file or at
# https://opensource.org/licenses/MIT.
#
# frozen_string_literal: true

require "graphql"

module ElasticGraph
  class GraphQL
    module Resolvers
      # Restores per-object resolver isolation under the GraphQL gem's experimental breadth-first
      # execution engine (`GraphQL::Execution::Next`).
      #
      # When a schema is built from SDL, the gem generates a batch resolver for each field which
      # loops over the objects at that field's position, calling our resolver lambda for each one:
      #
      #     objects.map { |object| definition_default_resolve.call(...) }
      #
      # That loop runs in a single fiber, so a resolver which blocks on the dataloader (as ours do,
      # via `QuerySource`) syncs immediately instead of letting the keys contributed by sibling
      # objects accumulate into one batch. The legacy engine gave each object its own fiber, which
      # is what allows `QuerySource` to collapse N datastore queries into a single `msearch`
      # request. Without this, one `msearch` becomes N.
      #
      # To restore that, each resolver lambda is wrapped so that it immediately returns a lazy
      # placeholder instead of resolving. The engine collects the placeholders for all the objects
      # at a field's position (and for sibling fields, since they share this source instance) and
      # then resolves them together in `Source#fetch`, which runs each resolver in its own fiber.
      # By the time those fibers block on the dataloader, every key is pending, so they get batched.
      #
      # This also restores per-object error isolation. The generated batch resolver applies an
      # `ExecutionError` raised for one object to every object in the batch, so each resolver's
      # error is captured separately here.
      # Deferring is not free--each slot costs a fiber--so only resolvers that can actually reach
      # the dataloader are wrapped. These are the built-in resolvers which cannot: they compute
      # their result from the parent object alone and never issue a datastore query. Every other
      # resolver, including any registered by an extension or an application, is wrapped, since
      # deferring a resolver that did not need it only costs performance while failing to defer one
      # that did would cost correctness.
      #
      # `object_with_lookahead`/`object_without_lookahead` delegate to `object.resolve`, and the
      # `ResolvableValue` objects they delegate to likewise only read from data already fetched.
      module BreadthFirstFanout
        NON_DATASTORE_RESOLVER_NAMES = [
          :get_record_field_value,
          :namespace_ref,
          :object_with_lookahead,
          :object_without_lookahead
        ].to_set.freeze

        # Holds one deferred resolver invocation along with its outcome. This is mutable because it
        # is handed to `Source` before the resolver has run.
        Slot = ::Struct.new(:thunk, :value, :error)

        # The lazy placeholder handed back to the engine in place of a resolved value. The engine
        # calls `#resolve` (registered via `GraphQL::Schema.lazy_resolve`) once it has walked the
        # rest of the current level, which is what gives `Source` a full batch to work with.
        #
        # We can't hand back the `GraphQL::Dataloader::Request` that `Source#request` returns, even
        # though the gem registers a lazy method for it: doing so is deprecated as of graphql-ruby
        # 2.6, and the deprecation has no lazy-preserving substitute (the suggested `.load` is
        # blocking, which is precisely what breaks batching here).
        class Deferred
          def initialize(request)
            @request = request
          end

          def resolve
            @request.load
          end
        end

        # Resolves a batch of slots, giving each its own fiber so that the dataloader keys they
        # request accumulate into a single batch.
        class Source < ::GraphQL::Dataloader::Source
          def fetch(slots)
            # `run_isolated` sets aside the dataloader's current queue and pending keys, runs the
            # jobs appended below (each in its own fiber), then restores what it set aside.
            dataloader.run_isolated do
              slots.each do |slot|
                dataloader.append_job do
                  slot.value = slot.thunk.call
                rescue ::GraphQL::ExecutionError => e
                  slot.error = e
                end
              end
            end

            # Returning an error in a slot's result position is what keeps it isolated to that slot:
            # `Dataloader::Source#result_for` re-raises a result that is a `StandardError`, so only
            # the `Deferred#resolve` for this slot raises, and the engine turns that into a field
            # error just as it would for a resolver that raised.
            slots.map { |slot| slot.error || slot.value }
          end
        end

        # Registers `Deferred` as a lazy class on `graphql_schema`, which both teaches the engine
        # how to resolve our placeholders and--as a side effect--makes the schema report
        # `resolves_lazies?`. That predicate gates all lazy handling in the breadth-first engine,
        # and it infers its answer by counting registered lazy classes, returning `false` unless
        # there are more than the two the gem registers by default.
        def self.apply(graphql_schema)
          graphql_schema.lazy_resolve(Deferred, :resolve)
        end

        # Indicates if `resolver_name` needs its resolutions deferred via `wrap`.
        def self.needed_for?(resolver_name)
          !NON_DATASTORE_RESOLVER_NAMES.include?(resolver_name)
        end

        # Wraps `resolver_lambda` so that it defers to `Source`.
        def self.wrap(resolver_lambda)
          lambda do |object, args, context|
            slot = Slot.new(-> { resolver_lambda.call(object, args, context) })
            Deferred.new(context.dataloader.with(Source).request(slot))
          end
        end
      end
    end
  end
end
