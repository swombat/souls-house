#!/usr/bin/env ruby
# frozen_string_literal: true

# Rewrites test/ci/rails_timings.json, the seconds per test file that
# scripts/run-rails-shard.rb balances the CI shards on.
#
#   bin/test                              # a full run: padded_cell records every test's time
#   ruby scripts/rails-test-timings.rb    # sums them per file
#
# padded_cell keeps "Klass#test_name<TAB>seconds" in tmp/padded_cell/timings.tsv
# and lists the same ids with their files statically, so no test is loaded here.
# A test the static list cannot see (define_method, inherited) is charged to
# the file of its class.
require "json"
require "open3"

root = File.expand_path("..", __dir__)
Dir.chdir(root)
source = "tmp/padded_cell/timings.tsv"
abort "#{source} is missing: run bin/test first" unless File.file?(source)
timings = File.foreach(source, chomp: true).to_h { |line| id, seconds = line.split("\t", 2); [id, Float(seconds)] }

listing, status = Open3.capture2("bundle", "exec", "padded_cell", "--list")
abort listing unless status.success?
per_file = Hash.new(0.0)
file_of_class = {}
unmeasured = 0
listing.each_line(chomp: true) do |line|
  location, id = line.split(" ", 2)
  file = location.split(":", 2).first
  file_of_class[id.split("#", 2).first] ||= file
  if (seconds = timings.delete(id))
    per_file[file] += seconds
  else
    unmeasured += 1
  end
end
timings.delete_if do |id, seconds|
  file = file_of_class[id.split("#", 2).first]
  per_file[file] += seconds if file
  file
end

output = "test/ci/rails_timings.json"
File.write(output, JSON.pretty_generate(per_file.sort.to_h { |file, seconds| [file, seconds.round(2)] }) + "\n")
puts "#{output}: #{per_file.size} files, #{per_file.values.sum.round} s of test time; " \
     "#{unmeasured} listed tests without a time, #{timings.size} timed tests with no file to charge"
