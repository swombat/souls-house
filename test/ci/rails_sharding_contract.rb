# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require "open3"
require "rbconfig"
require "json"
require_relative "../../scripts/lib/rails_test_shard"

class RailsTestShardTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @root = Dir.mktmpdir("rails-shards")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def write(path, source = "# fixture\n")
    FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
    File.write(File.join(@root, path), source)
  end

  def test_discovery_matches_rails_except_separately_run_system
    %w[models/a lib/b house/c migrations/d operations/e].each { |name| write("test/#{name}_test.rb") }
    %w[system dummy fixtures isolation/assets/node_modules].each { |dir| write("test/#{dir}/ignored_test.rb") }
    write("test/ci/rails_sharding_contract.rb")
    write("test/support/helper.rb")
    assert_equal %w[test/house/c_test.rb test/lib/b_test.rb test/migrations/d_test.rb test/models/a_test.rb test/operations/e_test.rb],
      RailsTestShard::Plan.new(@root).files
  end

  def test_connected_components_include_transitive_support_and_cycles
    write("test/models/a_test.rb", 'require_relative "../support/shared"')
    write("test/support/shared.rb", 'require_relative "../models/b_test"')
    write("test/models/b_test.rb", 'require_relative "c_test.rb"')
    write("test/models/c_test.rb", 'require_relative "a_test"')
    write("test/models/d_test.rb")
    plan = RailsTestShard::Plan.new(@root)
    assert_equal [%w[test/models/a_test.rb test/models/b_test.rb test/models/c_test.rb], ["test/models/d_test.rb"]], plan.groups
    assert_equal plan.files, plan.shards(3).flatten.sort
    assert_equal plan.files.length, plan.shards(3).flatten.uniq.length
  end

  def test_balancing_is_deterministic_and_uses_group_byte_size
    %w[c b a].each_with_index { |name, index| write("test/#{name}_test.rb", "#" * (index + 1) * 10) }
    plan = RailsTestShard::Plan.new(@root)
    assert_equal [["test/a_test.rb"], ["test/b_test.rb", "test/c_test.rb"]], plan.shards(2)
    assert_equal plan.shards(3), RailsTestShard::Plan.new(@root).shards(3)
  end

  def test_measured_seconds_outweigh_byte_size_and_scale_unmeasured_files
    write("test/a_test.rb", "#" * 10)
    write("test/b_test.rb", "#" * 400)
    write("test/c_test.rb", "#" * 400)
    write("test/d_test.rb", "#" * 200)
    write("test/ci/rails_timings.json",
      JSON.generate("test/a_test.rb" => 10, "test/b_test.rb" => 1, "test/c_test.rb" => 1, "test/gone_test.rb" => 50))
    plan = RailsTestShard::Plan.new(@root)
    # d has no time: 200 bytes at the measured 12 s / 810 bytes. A deleted file's time is ignored.
    assert_in_delta 200 * 12.0 / 810, plan.weight(["test/d_test.rb"]), 0.001
    assert_equal [["test/a_test.rb"], %w[test/b_test.rb test/c_test.rb test/d_test.rb]], plan.shards(2)
    output = StringIO.new
    assert_equal 0, RailsTestShard.run(["1", "2"], root: @root, executor: ->(_) { true }, out: output)
    assert_equal "Rails shard 1/2: 1 files, 10 s of measured test time\ntest/a_test.rb\n", output.string
  end

  def test_repository_timings_are_current_enough_to_balance_on
    plan = RailsTestShard::Plan.new(ROOT)
    measured = plan.timings.keys & plan.files
    assert_operator measured.size, :>=, (plan.files.size * 0.8).ceil,
      "test/ci/rails_timings.json has gone stale: bin/test, then ruby scripts/rails-test-timings.rb"
    assert plan.timings.values.all? { |seconds| seconds.is_a?(Numeric) && seconds >= 0 }
  end

  def test_static_requires_and_noncode_mentions
    write("test/a_test.rb", <<~'RUBY')
      # require_relative dynamic
      text = "require_relative dynamic"
      script = <<~SCRIPT
        require #{dynamic}
      SCRIPT
      require("b_test")
      require Rails.root.join("test", "c_test")
      require Rails.root.join("config/house")
      Marshal.load(Marshal.dump({}))
    RUBY
    write("test/b_test.rb")
    write("test/c_test.rb")
    assert_equal [%w[test/a_test.rb test/b_test.rb test/c_test.rb]], RailsTestShard::Plan.new(@root).groups
  end

  def test_dynamic_loading_fails_closed
    ['require_relative path', 'require "#{path}"', 'Kernel.require(path)', 'load(path)', 'require_relative'].each do |source|
      write("test/a_test.rb", source)
      error = assert_raises(RailsTestShard::Error) { RailsTestShard::Plan.new(@root).groups }
      assert_match(/dynamic/, error.message)
    end
  end

  def test_missing_relative_dependency_and_syntax_errors_fail_closed
    ['require_relative "missing"', "class Broken"].each do |source|
      write("test/a_test.rb", source)
      assert_raises(RailsTestShard::Error) { RailsTestShard::Plan.new(@root).groups }
    end
  end

  def test_utf8_source_parses_without_locale_environment
    write("test/a_test.rb", "# ×\nrequire_relative \"b_test\"\n")
    write("test/b_test.rb")
    assert_equal [%w[test/a_test.rb test/b_test.rb]], RailsTestShard::Plan.new(@root).groups
  end

  def test_runner_executes_from_root_and_preserves_parent_worker_setting
    write("test/a_test.rb")
    write("bin/test", <<~RUBY)
      #!#{RbConfig.ruby}
      exit(Dir.pwd == #{ @root.inspect } && ENV["PARALLEL_WORKERS"] == "4" ? 0 : 9)
    RUBY
    File.chmod(0o700, File.join(@root, "bin/test"))
    previous = ENV["PARALLEL_WORKERS"]
    ENV["PARALLEL_WORKERS"] = "4"
    assert_equal 0, RailsTestShard.run(["1", "3"], root: @root, out: StringIO.new)
    assert_equal "4", ENV["PARALLEL_WORKERS"]
  ensure
    previous ? ENV["PARALLEL_WORKERS"] = previous : ENV.delete("PARALLEL_WORKERS")
  end

  def test_excluded_cross_test_dependency_fails_closed
    write("test/a_test.rb", 'require_relative "system/browser_test"')
    write("test/system/browser_test.rb")
    assert_raises(RailsTestShard::Error) { RailsTestShard::Plan.new(@root).groups }
  end

  def test_invalid_arguments_never_execute
    [[], ["0", "3"], ["4", "3"], ["1", "0"], ["-1", "3"], ["1x", "3"], ["1", "3", "extra"]].each do |args|
      assert_equal 1, RailsTestShard.run(args, root: @root,
        executor: ->(_) { flunk "invalid arguments executed Rails" }, out: StringIO.new, err: StringIO.new)
    end
  end

  def test_empty_shard_never_runs_bare_test
    write("test/a_test.rb")
    assert_equal 0, RailsTestShard.run(["3", "3"], root: @root,
      executor: ->(_) { flunk "empty shard executed Rails" }, out: StringIO.new)
  end

  def test_listing_and_execution
    write("test/a_test.rb")
    output = StringIO.new
    assert_equal 0, RailsTestShard.run(["--list", "1", "3"], root: @root,
      executor: ->(_) { flunk "list executed Rails" }, out: output)
    assert_equal "test/a_test.rb\n", output.string
    command = nil
    assert_equal 0, RailsTestShard.run(["1", "3"], root: @root,
      executor: ->(args) { command = args; true }, out: StringIO.new)
    assert_equal [File.join(@root, "bin/test"), "--timeout", "120", "test/a_test.rb"], command
  end

  def test_child_failure_status_propagates_without_credentials
    write("test/a_test.rb")
    home = File.join(@root, "home")
    FileUtils.mkdir_p(home)
    command = [RbConfig.ruby, "-e", 'exit 23']
    result = RailsTestShard.run(["1", "3"], root: @root, out: StringIO.new,
      executor: ->(_) { system({ "PATH" => ENV.fetch("PATH"), "HOME" => home }, *command, unsetenv_others: true) })
    assert_equal 23, result
  end

  def test_repository_partition_and_known_review_groups
    plan = RailsTestShard::Plan.new(ROOT)
    shards = plan.shards(3)
    assert_equal plan.files, shards.flatten.sort
    assert_equal plan.files.size, shards.flatten.uniq.size
    [
      %w[test/models/message_dispatch_test.rb test/models/mira_dispatch_recovery_review_test.rb test/models/mira_dispatch_horizon_review_test.rb],
      %w[test/controllers/api/v1/attachments_controller_test.rb test/controllers/api/v1/mira_discard_attachment_review_test.rb],
      %w[test/controllers/api/app/v1/write_api_test.rb test/controllers/api/app/v1/mira_dispatch_errors_review_test.rb],
      %w[test/controllers/api/app/v1/send_concurrency_test.rb test/controllers/api/app/v1/mira_after_commit_acceptance_review_test.rb]
    ].each do |group|
      assert_equal 1, shards.count { |shard| (group - shard).empty? }, group.inspect
    end
    refute shards.flatten.any? { |file| file.start_with?("test/system/") }
    refute_includes shards.flatten, "test/ci/rails_sharding_contract.rb"
  end

  def test_cli_list_is_a_machine_readable_contract_without_credentials
    output, errors, status = Open3.capture3(
      { "PATH" => ENV.fetch("PATH"), "HOME" => @root },
      RbConfig.ruby, File.join(ROOT, "scripts/run-rails-shard.rb"), "--list", "1", "3",
      unsetenv_others: true, chdir: @root)
    assert status.success?, errors
    assert_equal RailsTestShard::Plan.new(ROOT).shards(3).first, output.lines.map(&:chomp)
    assert_empty errors
  end

  # bin/test with a stub bin/instance that prints the padded_cell arguments.
  def bin_test_arguments(*argv, workers: "4")
    write("bin/test", File.read(File.join(ROOT, "bin/test")))
    write("bin/instance", "#!#{RbConfig.ruby}\nputs ARGV.drop_while { |a| a != \"padded_cell\" }.drop(1)\n")
    %w[bin/test bin/instance].each { |path| File.chmod(0o700, File.join(@root, path)) }
    output, errors, status = Open3.capture3({ "PARALLEL_WORKERS" => workers },
      RbConfig.ruby, File.join(@root, "bin/test"), *argv)
    assert status.success?, errors
    output.lines.map(&:chomp)
  end

  def test_bin_test_defaults_jobs_from_parallel_workers_unless_given_before_double_dash
    assert_equal %w[--jobs 4 test/a_test.rb], bin_test_arguments("test/a_test.rb")
    assert_equal %w[-j 2 test/a_test.rb], bin_test_arguments("-j", "2", "test/a_test.rb")
    assert_equal %w[--jobs=2], bin_test_arguments("--jobs=2")
    assert_equal %w[--jobs 4 -- --jobs], bin_test_arguments("--", "--jobs")
    assert_equal %w[test/a_test.rb], bin_test_arguments("test/a_test.rb", workers: "0")
  end
end
