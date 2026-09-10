# frozen_string_literal: true

require "rake/testtask"
require "bundler/gem_tasks"

Rake::TestTask.new(:test) do |test|
  test.libs << "lib" << "test"
  test.pattern = "test/**/*_test.rb"
end

namespace :test do
  Rake::TestTask.new(:oracle) do |test|
    test.libs << "lib" << "test"
    test.pattern = "test/oracle_test.rb"
  end
end

desc "Measure performance (BUDGET=1 enables assertions)"
task :bench do
  Dir["bench/*.rb"].sort.each { |path| ruby "--yjit", path }
end

desc "Build and smoke-test an isolated local gem install"
task :isolation do
  ruby "script/check_isolation.rb"
end

task default: [:test, :isolation]
