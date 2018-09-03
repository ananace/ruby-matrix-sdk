require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList['test/**/*_test.rb']
end

if ENV['GENERATE_REPORTS'] == 'true'
  require 'ci/reporter/rake/test_unit'
  task :test => 'ci:setup:testunit'
end

task :default => :test
