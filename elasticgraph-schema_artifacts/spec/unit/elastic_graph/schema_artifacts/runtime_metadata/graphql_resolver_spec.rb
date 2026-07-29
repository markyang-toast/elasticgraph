# Copyright 2024 - 2026 Block, Inc.
#
# Use of this source code is governed by an MIT-style
# license that can be found in the LICENSE file or at
# https://opensource.org/licenses/MIT.
#
# frozen_string_literal: true

require "elastic_graph/schema_artifacts/runtime_metadata/graphql_resolver"

module ElasticGraph
  module SchemaArtifacts
    module RuntimeMetadata
      RSpec.describe GraphQLResolver do
        it "loads a resolver with lookahead dynamically" do
          resolver = GraphQLResolver.new(
            needs_lookahead: true,
            needs_ast_node: false,
            resolver_ref: {
              "name" => "ElasticGraph::GraphQLResolverWithLookahead",
              "require_path" => "elastic_graph/spec_support/example_extensions/graphql_resolvers"
            }
          )

          expect(resolver.load_resolver.extension_class).to be GraphQLResolverWithLookahead
        end

        it "loads a resolver with an AST node dynamically" do
          resolver = GraphQLResolver.new(
            needs_lookahead: false,
            needs_ast_node: true,
            resolver_ref: {
              "name" => "ElasticGraph::GraphQLResolverWithASTNode",
              "require_path" => "elastic_graph/spec_support/example_extensions/graphql_resolvers"
            }
          )

          expect(resolver.load_resolver.extension_class).to be GraphQLResolverWithASTNode
        end

        it "loads a resolver without lookahead dynamically" do
          resolver = GraphQLResolver.new(
            needs_lookahead: false,
            needs_ast_node: false,
            resolver_ref: {
              "name" => "ElasticGraph::GraphQLResolverWithoutLookahead",
              "require_path" => "elastic_graph/spec_support/example_extensions/graphql_resolvers"
            }
          )

          expect(resolver.load_resolver.extension_class).to be GraphQLResolverWithoutLookahead
        end

        it "raises an error if `needs_lookahead` is true for a resolver without lookahead" do
          resolver = GraphQLResolver.new(
            needs_lookahead: true,
            needs_ast_node: false,
            resolver_ref: {
              "name" => "ElasticGraph::GraphQLResolverWithoutLookahead",
              "require_path" => "elastic_graph/spec_support/example_extensions/graphql_resolvers"
            }
          )

          expect {
            resolver.load_resolver
          }.to raise_error Errors::InvalidExtensionError
        end

        it "raises an error if `needs_lookahead` is false for a resolver with lookahead" do
          resolver = GraphQLResolver.new(
            needs_lookahead: false,
            needs_ast_node: false,
            resolver_ref: {
              "name" => "ElasticGraph::GraphQLResolverWithLookahead",
              "require_path" => "elastic_graph/spec_support/example_extensions/graphql_resolvers"
            }
          )

          expect {
            resolver.load_resolver
          }.to raise_error Errors::InvalidExtensionError
        end

        it "raises an error if `needs_ast_node` is true for a resolver that does not accept an AST node" do
          resolver = GraphQLResolver.new(
            needs_lookahead: false,
            needs_ast_node: true,
            resolver_ref: {
              "name" => "ElasticGraph::GraphQLResolverWithoutLookahead",
              "require_path" => "elastic_graph/spec_support/example_extensions/graphql_resolvers"
            }
          )

          expect {
            resolver.load_resolver
          }.to raise_error Errors::InvalidExtensionError
        end

        it "raises an error if `needs_ast_node` is false for a resolver that accepts an AST node" do
          resolver = GraphQLResolver.new(
            needs_lookahead: false,
            needs_ast_node: false,
            resolver_ref: {
              "name" => "ElasticGraph::GraphQLResolverWithASTNode",
              "require_path" => "elastic_graph/spec_support/example_extensions/graphql_resolvers"
            }
          )

          expect {
            resolver.load_resolver
          }.to raise_error Errors::InvalidExtensionError
        end

        it "defaults `needs_ast_node` to `false` when loading from schema artifacts dumped before it existed" do
          resolver = GraphQLResolver.from_hash({
            "needs_lookahead" => false,
            "resolver_ref" => {
              "name" => "ElasticGraph::GraphQLResolverWithoutLookahead",
              "require_path" => "elastic_graph/spec_support/example_extensions/graphql_resolvers"
            }
          })

          expect(resolver.needs_ast_node).to be false
          expect(resolver.load_resolver.extension_class).to be GraphQLResolverWithoutLookahead
        end
      end
    end
  end
end
