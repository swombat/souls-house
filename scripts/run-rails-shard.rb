#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/rails_test_shard"

exit RailsTestShard.run(ARGV, root: File.expand_path("..", __dir__))
