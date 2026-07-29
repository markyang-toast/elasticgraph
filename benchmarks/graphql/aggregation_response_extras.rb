#!/usr/bin/env ruby
# Copyright 2024 - 2026 Block, Inc.
#
# Use of this source code is governed by an MIT-style
# license that can be found in the LICENSE file or at
# https://opensource.org/licenses/MIT.
#
# frozen_string_literal: true

# Benchmarks the cost of the `:lookahead` extra vs the `:ast_node` extra on
# aggregation response fields (`groupedBy`, `aggregatedValues`, `subAggregations`).
#
# Those resolvers only need the response key of the field being resolved, but
# requesting `:lookahead` makes graphql-ruby allocate a `Lookahead` per field per
# object, which is proportional to `buckets * fields` in an aggregation response.
# The `:ast_node` extra provides the same information (`ast_node.alias || ast_node.name`)
# without the allocation.
#
# This models the shape of an aggregation response rather than booting a full
# ElasticGraph instance, so that the measurement isolates the extras overhead.
#
# Run with:
#   bundle exec ruby benchmarks/graphql/aggregation_response_extras.rb

require "benchmark/ips"
require "graphql"
require "memory_profiler"

# A single aggregation bucket. `values` is keyed by response key, mirroring how
# the real resolvers look up values by the response key of the field.
Bucket = ::Struct.new(:count, :values)

# Builds a schema shaped like an aggregation response: a list of buckets, each
# with a `groupedBy` object exposing `num_fields` fields. Every field requests
# the given `extras` and resolves by looking up its response key in the bucket.
def build_schema(num_fields:, extras:)
  field_names = (1..num_fields).map { |i| "f#{i}" }

  grouped_by_type = Class.new(GraphQL::Schema::Object) do
    graphql_name "GroupedBy"

    field_names.each do |name|
      field name, String, null: true, extras: extras, resolver_method: :resolve_response_key
    end

    if extras == [:lookahead]
      define_method(:resolve_response_key) do |lookahead:|
        ast_node = lookahead.ast_nodes.first
        object.fetch(ast_node.alias || ast_node.name)
      end
    else
      define_method(:resolve_response_key) do |ast_node:|
        object.fetch(ast_node.alias || ast_node.name)
      end
    end
  end

  bucket_type = Class.new(GraphQL::Schema::Object) do
    graphql_name "Bucket"
    field :grouped_by, grouped_by_type, null: true
    field :count, Integer, null: true

    define_method(:grouped_by) { object.values }
  end

  query_type = Class.new(GraphQL::Schema::Object) do
    graphql_name "Query"
    field :nodes, [bucket_type], null: true

    define_method(:nodes) { context[:buckets] }
  end

  Class.new(GraphQL::Schema) do
    query(query_type)
  end
end

def build_query(field_names:)
  <<~GRAPHQL
    query AggregationQuery {
      nodes {
        count
        groupedBy {
    #{field_names.map { |f| "      #{f}" }.join("\n")}
        }
      }
    }
  GRAPHQL
end

def build_buckets(num_buckets:, field_names:)
  (1..num_buckets).map do |i|
    values = field_names.to_h { |name| [name, "#{name}-#{i}"] }
    Bucket.new(i, values)
  end
end

configs = [
  {label: "small", num_fields: 3, num_buckets: 10},
  {label: "medium", num_fields: 5, num_buckets: 100},
  {label: "large", num_fields: 10, num_buckets: 500},
  {label: "xlarge", num_fields: 15, num_buckets: 2000}
]

configs.each do |config|
  field_names = (1..config[:num_fields]).map { |i| "f#{i}" }
  document = GraphQL.parse(build_query(field_names: field_names))
  buckets = build_buckets(num_buckets: config[:num_buckets], field_names: field_names)

  lookahead_schema = build_schema(num_fields: config[:num_fields], extras: [:lookahead])
  ast_node_schema = build_schema(num_fields: config[:num_fields], extras: [:ast_node])

  execute = ->(schema) { schema.execute(document: document, context: {buckets: buckets}) }

  puts
  puts "=" * 70
  puts "#{config[:label]} — #{config[:num_buckets]} buckets x #{config[:num_fields]} fields = #{config[:num_buckets] * config[:num_fields]} resolved fields"
  puts "=" * 70

  # Sanity check: both schemas must resolve the same values with no errors.
  lookahead_result = execute.call(lookahead_schema).to_h
  ast_node_result = execute.call(ast_node_schema).to_h
  resolved_fields = lookahead_result.dig("data", "nodes")&.sum { |n| n.fetch("groupedBy").size }

  if lookahead_result.key?("errors") || lookahead_result != ast_node_result || resolved_fields != config[:num_buckets] * config[:num_fields]
    abort "results differ, contain errors, or resolved #{resolved_fields.inspect} fields — check benchmark setup: #{lookahead_result.inspect[0, 500]}"
  end

  Benchmark.ips do |x|
    x.config(time: 5, warmup: 2)

    x.report("extras: [:lookahead] (before)") { execute.call(lookahead_schema) }
    x.report("extras: [:ast_node] (after)") { execute.call(ast_node_schema) }

    x.compare!
  end
end

# The point of the optimization is avoiding a `Lookahead` allocation per field
# per object, so profile allocations for the largest config as well.
largest = configs.last
largest_field_names = (1..largest[:num_fields]).map { |i| "f#{i}" }
largest_document = GraphQL.parse(build_query(field_names: largest_field_names))
largest_buckets = build_buckets(num_buckets: largest[:num_buckets], field_names: largest_field_names)

{
  "extras: [:lookahead] (before)" => build_schema(num_fields: largest[:num_fields], extras: [:lookahead]),
  "extras: [:ast_node] (after)" => build_schema(num_fields: largest[:num_fields], extras: [:ast_node])
}.each do |label, schema|
  # Warm up so one-time schema/class lazy initialization isn't attributed to the run.
  schema.execute(document: largest_document, context: {buckets: largest_buckets})

  report = MemoryProfiler.report do
    schema.execute(document: largest_document, context: {buckets: largest_buckets})
  end

  puts
  puts "=" * 70
  puts "#{largest[:label]} memory profile — #{label}"
  puts "=" * 70
  puts "total allocated: #{report.total_allocated} objects (#{report.total_allocated_memsize} bytes)"
  puts "total retained:  #{report.total_retained} objects (#{report.total_retained_memsize} bytes)"
  puts
  puts "top allocated objects by class:"
  report.allocated_objects_by_class.first(10).each do |entry|
    puts "  #{entry[:count].to_s.rjust(8)}  #{entry[:data]}"
  end
end
