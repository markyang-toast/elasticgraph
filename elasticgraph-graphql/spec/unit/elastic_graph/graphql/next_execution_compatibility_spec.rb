# Copyright 2024 - 2026 Block, Inc.
#
# Use of this source code is governed by an MIT-style
# license that can be found in the LICENSE file or at
# https://opensource.org/licenses/MIT.
#
# frozen_string_literal: true

require "elastic_graph/graphql/next_execution_compatibility"

module ElasticGraph
  class GraphQL
    RSpec.describe NextExecutionCompatibility do
      describe ".apply" do
        it "patches the GraphQL gem classes the breadth-first engine needs patched" do
          NextExecutionCompatibility.apply(schema_with_directive)

          expect(::GraphQL::Execution::InputValues).to include NextExecutionCompatibility::InputValuesNullValueFix
          expect(::GraphQL::Execution::Finalize).to include NextExecutionCompatibility::FinalizeQueryLevelErrorFix
        end

        it "patches each of the schema's directives so a declarative one does not halt execution" do
          graphql_schema = schema_with_directive

          NextExecutionCompatibility.apply(graphql_schema)

          expect(graphql_schema.directives.values).to all satisfy { |directive_class|
            directive_class.singleton_class.include?(NextExecutionCompatibility::DeclarativeOperationDirective)
          }
        end

        it "is safe to call more than once, as it is applied per-schema but patches global classes" do
          NextExecutionCompatibility.apply(schema_with_directive)

          expect { NextExecutionCompatibility.apply(schema_with_directive) }.not_to raise_error
        end

        def schema_with_directive
          Class.new(::GraphQL::Schema) do
            directive(Class.new(::GraphQL::Schema::Directive) do
              graphql_name "eg_latency_slo_test"
              locations "QUERY"
              argument :ms, ::GraphQL::Types::Int
            end)
          end
        end
      end

      describe NextExecutionCompatibility::InputValuesNullValueFix do
        let(:input_values) do
          ::Class.new do
            def value_from_ast(value_node, type)
              # Stands in for the gem's implementation, which calls `value_node.arguments` on an
              # input-object type--the call that raises for a `NullValue` node.
              value_node.arguments
            end

            prepend NextExecutionCompatibility::InputValuesNullValueFix
          end.new
        end

        it "returns `nil` for a literal `null` on an input-object-typed argument" do
          value = input_values.value_from_ast(null_node, type_of_kind(input_object: true))

          expect(value).to be nil
        end

        it "defers to the gem for a literal `null` on an argument of any other type" do
          expect {
            input_values.value_from_ast(null_node, type_of_kind(input_object: false))
          }.to raise_error NoMethodError
        end

        it "defers to the gem for a non-null value node" do
          value_node = ::GraphQL::Language::Nodes::InputObject.new(arguments: [])

          expect(input_values.value_from_ast(value_node, type_of_kind(input_object: true))).to eq []
        end

        def null_node
          ::GraphQL::Language::Nodes::NullValue.new(name: "null")
        end

        # A real type is used rather than a double because `kind` is a class method on the GraphQL
        # gem's type classes, which a verified instance double will not stub.
        def type_of_kind(input_object:)
          if input_object
            ::Class.new(::GraphQL::Schema::InputObject) { graphql_name "MyFilterInput" }
          else
            ::GraphQL::Types::String
          end
        end
      end

      describe NextExecutionCompatibility::DeclarativeOperationDirective do
        it "returns `nil` so that execution continues without consulting the directive" do
          directive_class = ::Class.new do
            singleton_class.prepend NextExecutionCompatibility::DeclarativeOperationDirective
          end

          expect(directive_class.resolve_operation(nil, nil, nil, nil, nil)).to be nil
        end
      end

      describe NextExecutionCompatibility::FinalizeQueryLevelErrorFix do
        let(:finalize_class) do
          ::Class.new do
            attr_reader :seen_errors

            def initialize(query, data, runner)
              # Stands in for the gem's implementation, which computes `err.path - ...` for each
              # error--the call that raises for a query-level error, whose `path` is `nil`.
              @seen_errors = query.context.errors.map { |err| err.path - [] }
            end

            prepend NextExecutionCompatibility::FinalizeQueryLevelErrorFix
          end
        end

        it "hides pathless query-level errors from `Finalize`, which cannot place them in the data tree" do
          query = query_with_errors([error_with_path(nil), error_with_path(["widgets", 0])])

          finalize = finalize_class.new(query, nil, nil)

          expect(finalize.seen_errors).to eq [["widgets", 0]]
        end

        it "restores the hidden errors afterwards, so the runner still reports them in the response" do
          pathless = error_with_path(nil)
          with_path = error_with_path(["widgets", 0])
          query = query_with_errors([pathless, with_path])

          finalize_class.new(query, nil, nil)

          expect(query.context.errors).to contain_exactly(pathless, with_path)
        end

        it "restores the hidden errors even when `Finalize` raises" do
          pathless = error_with_path(nil)
          query = query_with_errors([pathless])
          raising_class = ::Class.new(finalize_class) do
            def initialize(query, data, runner)
              raise "boom"
            end
            prepend NextExecutionCompatibility::FinalizeQueryLevelErrorFix
          end

          expect { raising_class.new(query, nil, nil) }.to raise_error "boom"
          expect(query.context.errors).to contain_exactly(pathless)
        end

        it "leaves `context.errors` untouched when every error has a path" do
          with_path = error_with_path(["widgets", 0])
          query = query_with_errors([with_path])

          finalize = finalize_class.new(query, nil, nil)

          expect(finalize.seen_errors).to eq [["widgets", 0]]
          expect(query.context.errors).to contain_exactly(with_path)
        end

        def error_with_path(path)
          ::GraphQL::ExecutionError.new("an error").tap { |e| e.path = path }
        end

        def query_with_errors(errors)
          instance_double(::GraphQL::Query, context: instance_double(::GraphQL::Query::Context, errors: errors))
        end
      end
    end
  end
end
