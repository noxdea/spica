# frozen_string_literal: true

require_relative "../lib/spica"
require "objspace"

def elapsed
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
end

runs = Integer(ENV.fetch("RUNS", "5"))
raise "RUNS must be positive" unless runs.positive?
# Representative narrowing: first key c leaves 10,000 of 100,000 paths.
paths = Array.new(100_000) do |i|
  leaf = i % 10 == 0 ? "component" : "widget"
  "lib/group_#{i % 500}/#{leaf}_#{i}.rb"
end
# Warm the exact code paths, excluding JIT compilation from steady-state timings.
warm = Spica::Index.new(paths.first(2000))
20.times do
  session = warm.session
  %w[c co cm component_123].each { |query| session.query = query; session.matches(50) }
end
samples = Hash.new { |hash, key| hash[key] = [] }
index = nil
runs.times do
  GC.start
  samples[:build] << elapsed { index = Spica::Index.new(paths) }
end
runs.times do
  session = index.session
  samples[:first] << elapsed { session.query = "c"; session.matches(50) }
  raise "wrong first-key match count" unless session.total_matches == 10_000
  samples[:second] << elapsed { session.query = "co"; session.matches(50) }
  samples[:deep] << elapsed { session.query = "component_123"; session.matches(50) }
  samples[:backspace] << elapsed { session.query = "co"; session.matches(50) }
  session.query = "c"
  samples[:noncontiguous] << elapsed { session.query = "cm"; session.matches(50) }
end
# Retain the original all-hit stress corpus rather than hiding its cost.
stress = Spica::Index.new(Array.new(100_000) { |i| "src/group_#{i % 500}/component_#{i}.rb" })
runs.times do
  session = stress.session
  samples[:all_hit_first] << elapsed { session.query = "c"; session.matches(50) }
  samples[:all_hit_second] << elapsed { session.query = "co"; session.matches(50) }
end
10_000.times { Spica.score("amf", "app/models/foo.rb") }
runs.times { samples[:single] << elapsed { 10_000.times { Spica.score("amf", "app/models/foo.rb") } } / 10.0 }
median = samples.transform_values { |values| values.sort[values.length / 2] }
puts "#{RUBY_DESCRIPTION}; median of #{runs}; milliseconds except single score"
median.each { |name, value| puts format("%-20s %.4f%s", name, value, name == :single ? " us" : " ms") }
bytes = index.candidates.sum do |candidate|
  values = candidate.instance_variables.map { |variable| candidate.instance_variable_get(variable) }.uniq(&:object_id)
  ObjectSpace.memsize_of(candidate) + values.sum { |value| ObjectSpace.memsize_of(value) }
end
puts format("retained candidate records: %.2f MiB (%.1f bytes/candidate, excludes Index hash/input array)", bytes / 1048576.0, bytes / 100_000.0)
gates = {build: 400, first: 40, second: 5, backspace: 1, single: 3}
if ENV["BUDGET"] == "1"
  failures = gates.select { |name, limit| median.fetch(name) >= limit }
  abort "budgets exceeded: #{failures.keys.join(', ')}" unless failures.empty?
end
