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
    # Patches around bugs in the GraphQL gem's experimental breadth-first execution engine
    # (`GraphQL::Execution::Next`) which prevent ElasticGraph's schema from executing on it. Both
    # patches restore the behavior the legacy engine already has, and both are applied only when the
    # breadth-first engine is enabled, so the legacy code path is entirely unaffected.
    #
    # These have been reported upstream; this file should be deleted once they are fixed.
    module NextExecutionCompatibility
      # Bug 1: `Execution::InputValues#value_from_ast` handles a literal `null` for list-typed
      # arguments, but not for input-object-typed ones--it calls `value_node.arguments` on the
      # `NullValue` AST node, raising `NoMethodError`. (The gem's own source flags the gap with a
      # `# TODO manually handle NullValue here?` comment on the affected branch.)
      #
      # ElasticGraph hits this on any query with an explicitly null filter (e.g.
      # `widgets(filter: {name: null})`), which we treat the same as an unmentioned filter.
      module InputValuesNullValueFix
        def value_from_ast(value_node, type)
          return nil if value_node.is_a?(::GraphQL::Language::Nodes::NullValue) && type.kind.input_object?
          super
        end
      end

      # Bug 2: `Execution::Runner#begin_execute` treats every directive definition whose locations
      # include a runtime location (such as `QUERY`) as one that participates in execution, and
      # calls `resolve_operation` on it. No such method is defined anywhere in the gem, so any
      # schema with a custom directive on `QUERY` raises `NoMethodError`.
      #
      # ElasticGraph defines `@eg_latency_slo(ms: Int!) on QUERY`, which is purely declarative: we
      # read it off the query's AST after execution to log an SLO result. Returning `nil` here
      # matches the legacy engine, which continues execution without consulting the directive.
      module DeclarativeOperationDirective
        def resolve_operation(operation, query, objects, arguments, context)
          nil
        end
      end

      # Bug 3: `Execution::Finalize#initialize` walks `query.context.errors` and computes
      # `err.path - @current_exec_path` for each one. Query-level errors--those added via the public
      # `context.add_error`--have no `path` (it is `nil`, and `ExecutionError#to_h` omits the key
      # accordingly), so this raises `NoMethodError: undefined method '-' for nil`.
      #
      # Such an error has no position in the data tree, so there is nothing for `Finalize` to attach
      # it to. Filtering it out here matches the legacy engine, which still reports it in the
      # response `errors` array (the runner reads `context.errors` separately for that).
      #
      # `elasticgraph-apollo` hits this: its `_entities` resolver reports a per-representation
      # problem with `context.add_error` while still returning the entities it could resolve.
      module FinalizeQueryLevelErrorFix
        def initialize(query, data, runner)
          errors = query.context.errors
          pathless_errors = errors.reject(&:path)

          if pathless_errors.empty?
            super
          else
            errors.replace(errors - pathless_errors)
            begin
              super
            ensure
              errors.replace(errors + pathless_errors)
            end
          end
        end
      end

      # Applies the patches to the given schema. Safe to call more than once.
      def self.apply(graphql_schema)
        unless ::GraphQL::Execution::InputValues.include?(InputValuesNullValueFix)
          ::GraphQL::Execution::InputValues.prepend(InputValuesNullValueFix)
        end

        unless ::GraphQL::Execution::Finalize.include?(FinalizeQueryLevelErrorFix)
          ::GraphQL::Execution::Finalize.prepend(FinalizeQueryLevelErrorFix)
        end

        graphql_schema.directives.each_value do |directive_class|
          singleton = directive_class.singleton_class
          singleton.prepend(DeclarativeOperationDirective) unless singleton.include?(DeclarativeOperationDirective)
        end
      end
    end
  end
end
