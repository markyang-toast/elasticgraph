# Copyright 2024 - 2026 Block, Inc.
#
# Use of this source code is governed by an MIT-style
# license that can be found in the LICENSE file or at
# https://opensource.org/licenses/MIT.
#
# frozen_string_literal: true

require "elastic_graph/schema_artifacts/runtime_metadata/extension_loader"

module ElasticGraph
  module SchemaArtifacts
    module RuntimeMetadata
      # @private
      class GraphQLResolver < ::Data.define(:needs_lookahead, :needs_ast_node, :resolver_ref)
        def self.with_lookahead_loader
          @with_lookahead_loader ||= ExtensionLoader.new(InterfaceWithLookahead)
        end

        def self.with_ast_node_loader
          @with_ast_node_loader ||= ExtensionLoader.new(InterfaceWithASTNode)
        end

        def self.without_lookahead_loader
          @without_lookahead_loader ||= ExtensionLoader.new(InterfaceWithoutLookahead)
        end

        NEEDS_AST_NODE = "needs_ast_node"
        NEEDS_LOOKAHEAD = "needs_lookahead"
        RESOLVER_REF = "resolver_ref"

        def load_resolver
          loader =
            if needs_lookahead
              GraphQLResolver.with_lookahead_loader
            elsif needs_ast_node
              GraphQLResolver.with_ast_node_loader
            else
              GraphQLResolver.without_lookahead_loader
            end

          Extension.load_from_hash(resolver_ref, via: loader)
        end

        def self.from_hash(hash)
          new(
            needs_lookahead: hash.fetch(NEEDS_LOOKAHEAD),
            # Older schema artifacts (dumped before `needs_ast_node` existed) won't have this key.
            needs_ast_node: hash.fetch(NEEDS_AST_NODE, false),
            resolver_ref: hash.fetch(RESOLVER_REF)
          )
        end

        def to_dumpable_hash
          {
            # Keys here are ordered alphabetically; please keep them that way.
            NEEDS_AST_NODE => needs_ast_node,
            NEEDS_LOOKAHEAD => needs_lookahead,
            RESOLVER_REF => resolver_ref
          }
        end

        # @private
        class InterfaceWithLookahead
          def initialize(elasticgraph_graphql:, config:)
            # must be defined, but nothing to do
          end

          def resolve(field:, object:, args:, context:, lookahead:)
          end
        end

        # @private
        class InterfaceWithASTNode
          def initialize(elasticgraph_graphql:, config:)
            # must be defined, but nothing to do
          end

          def resolve(field:, object:, args:, context:, ast_node:)
          end
        end

        # @private
        class InterfaceWithoutLookahead
          def initialize(elasticgraph_graphql:, config:)
            # must be defined, but nothing to do
          end

          def resolve(field:, object:, args:, context:)
          end
        end
      end
    end
  end
end
