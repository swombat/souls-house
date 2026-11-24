require "test_helper"

class Agents::StorageUsageTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "offline", uuid: SecureRandom.uuid, sandbox_host: Agents::Config.sandbox_host)
    @service = Agents::StorageUsage.new(@agent)
  end

  test "measures all five persistent volumes without starting the resident" do
    commands = []
    capture = lambda do |*args|
      commands << args
      output = Agents::VolumeSet.new(@agent).names.keys.map { |key| "12\t/measure/#{key}\n" }.join
      { ok: true, stdout: args.first == "run" ? output : "", stderr: "" }
    end
    @service.stub(:capture, capture) do
      result = @service.call
      assert_equal "measured", result[:status]
      assert_equal 5 * 12 * 1024, result[:bytes]
      assert_equal 5, result[:volumes].size
      assert result[:measured_at]
    end
    run = commands.find { |args| args.first == "run" }
    assert_includes run, "--read-only"
    assert_includes run, "none"
    assert_equal 5, run.count("--mount")
    assert run.grep(/type=volume/).all? { |mount| mount.end_with?(",readonly") }
    assert_equal "rm", commands.last.first
    assert_not commands.any? { |args| %w[start exec].include?(args.first) }
  end

  test "helper can finish a large home: init reaps du, one CPU, its own timeout first" do
    calls = []
    capture = lambda do |*args, seconds: Agents::StorageUsage::COMMAND_SECONDS|
      calls << [ args, seconds ]
      output = Agents::VolumeSet.new(@agent).names.keys.map { |key| "1\t/measure/#{key}\n" }.join
      { ok: true, stdout: args.first == "run" ? output : "", stderr: "" }
    end
    @service.stub(:capture, capture) do
      result = @service.call
      assert_equal "measured", result[:status]
      assert_kind_of Float, result[:attempt_seconds]
    end
    run, seconds = calls.find { |args, _| args.first == "run" }
    # Without --init busybox timeout execs du as PID 1, which ignores SIGTERM.
    assert_includes run, "--init"
    assert_equal "1", run[run.index("--cpus") + 1]
    assert_equal %w[nice -n 19 timeout 300 du -sk], run[run.index("busybox:1.37") + 1, 7]
    assert_operator seconds, :>, Agents::StorageUsage::DU_SECONDS
    assert calls.reject { |args, _| args.first == "run" }.all? { |_, s| s == Agents::StorageUsage::COMMAND_SECONDS }
  end

  test "a timeout keeps the last reading and records why and how long" do
    @agent.update_columns(storage_usage: { "bytes" => 1234, "measured_at" => 1.day.ago.iso8601, "status" => "measured" })
    capture = lambda do |*args, **|
      raise Timeout::Error if args.first == "run"

      { ok: true, stdout: "", stderr: "" }
    end
    @service.stub(:capture, capture) do
      result = @service.call
      assert_equal "unavailable", result["status"]
      assert_equal 1234, result["bytes"]
      assert_equal "timeout", result["failure"]
      assert_kind_of Float, result["attempt_seconds"]
    end
  end

  test "a later success clears the recorded failure" do
    @agent.update_columns(storage_usage: { "bytes" => 1, "failure" => "timeout", "attempt_seconds" => 330.0 })
    capture = lambda do |*args, **|
      output = Agents::VolumeSet.new(@agent).names.keys.map { |key| "2\t/measure/#{key}\n" }.join
      { ok: true, stdout: args.first == "run" ? output : "", stderr: "" }
    end
    @service.stub(:capture, capture) do
      result = @service.call.stringify_keys
      assert_equal "measured", result["status"]
      assert_not result.key?("failure")
    end
  end

  test "missing volumes are never mounted and readings are partial" do
    capture = lambda do |*args|
      if args.first == "volume"
        { ok: args[2].end_with?("-identity"), stdout: "", stderr: "" }
      else
        { ok: true, stdout: "0\t/measure/identity\n", stderr: "" }
      end
    end
    @service.stub(:capture, capture) do
      result = @service.call
      assert_equal "partial", result[:status]
      assert_equal 0, result[:bytes]
      assert_equal %w[chaos repo work state], result[:missing_volumes]
    end
  end

  test "failed measurement preserves last reading but marks it unavailable" do
    @agent.update_columns(storage_usage: { "bytes" => 1234, "measured_at" => 1.day.ago.iso8601 })
    @service.stub(:capture, { ok: false, stdout: "", stderr: "private error" }) do
      result = @service.call
      assert_equal "unavailable", result["status"]
      assert_equal 1234, result["bytes"]
      assert_not_includes result.to_json, "private error"
    end
  end

  test "inline and remote host agents do not invoke docker" do
    @service.stub(:capture, ->(*) { flunk "must not invoke Docker" }) do
      @agent.runtime = "inline"
      assert_equal "not_applicable", @service.call[:status]
      @agent.runtime = "external"
      @agent.sandbox_host = "different-host"
      assert_equal "unavailable", @service.call["status"]
    end
  end

  test "invalid or incomplete output is not reported as disk usage" do
    @service.stub(:capture, { ok: true, stdout: "secret malformed output", stderr: "" }) do
      result = @service.call
      assert_equal "unavailable", result["status"]
      assert_nil result["bytes"]
    end
  end

  test "cleanup errors do not discard a completed measurement" do
    capture = lambda do |*args|
      raise Timeout::Error if args.first == "rm"

      output = Agents::VolumeSet.new(@agent).names.keys.map { |key| "1\t/measure/#{key}\n" }.join
      { ok: true, stdout: output, stderr: "" }
    end
    @service.stub(:capture, capture) do
      assert_equal "measured", @service.call[:status]
    end
  end

  test "lists cargo build caches over 1 GB in work and state, largest first, in a second read-only helper" do
    gb = 1024 * 1024
    runs = []
    capture = lambda do |*args, **|
      next { ok: true, stdout: "", stderr: "" } unless args.first == "run"

      runs << args
      stdout = if args.include?("du")
        Agents::VolumeSet.new(@agent).names.keys.map { |key| "1\t/measure/#{key}\n" }.join
      else
        "#{4 * gb}\t/measure/work/chaos-review/target\n" \
          "#{25 * gb}\t/measure/work/.cargo-target\n" \
          "512\t/measure/work/small/target\n" \
          "#{2 * gb}\t/measure/state/tools/chaos-target\n"
      end
      { ok: true, stdout:, stderr: "" }
    end
    @service.stub(:capture, capture) do
      result = @service.call
      assert_equal "measured", result[:status]
      assert_equal [ [ "work", ".cargo-target", 25 ], [ "work", "chaos-review/target", 4 ], [ "state", "tools/chaos-target", 2 ] ],
        result[:cache_dirs].map { |dir| [ dir["volume"], dir["path"], dir["bytes"] / 1.gigabyte ] }
      assert_not result.key?(:cache_dirs_failure)
    end
    walk = runs.last
    assert_equal 2, runs.size
    assert_equal 2, walk.count("--mount")
    assert walk.grep(/type=volume/).all? { |mount| mount.end_with?(",readonly") && mount.match?(%r{dst=/measure/(work|state),}) }
    assert_includes walk, "--read-only"
    assert_equal %w[/measure/work /measure/state], walk.last(2)
  end

  test "a failed cache walk keeps the home's total and says the list was not taken" do
    capture = lambda do |*args, **|
      next { ok: true, stdout: "", stderr: "" } unless args.first == "run"
      next { ok: false, stdout: "", stderr: "private" } unless args.include?("du")

      { ok: true, stdout: Agents::VolumeSet.new(@agent).names.keys.map { |key| "3\t/measure/#{key}\n" }.join, stderr: "" }
    end
    @service.stub(:capture, capture) do
      result = @service.call
      assert_equal "measured", result[:status]
      assert_equal 5 * 3 * 1024, result[:bytes]
      assert_equal "walk_failed", result[:cache_dirs_failure]
      assert_not result.key?(:cache_dirs)
    end
  end

  test "an unreadable cache line keeps the home's total: non-UTF-8 and forged records" do
    [ "#{2 * 1024 * 1024}\t/measure/work/bad-\xFF/target\n".b, "12\t/measure/identity\n" ].each do |cache_output|
      capture = lambda do |*args, **|
        next { ok: true, stdout: "", stderr: "" } unless args.first == "run"
        next { ok: true, stdout: cache_output, stderr: "" } unless args.include?("du")

        { ok: true, stdout: Agents::VolumeSet.new(@agent).names.keys.map { |key| "3\t/measure/#{key}\n" }.join, stderr: "" }
      end
      @service.stub(:capture, capture) do
        result = @service.call
        assert_equal "measured", result[:status]
        assert_equal 5 * 3 * 1024, result[:bytes]
        assert_equal "unreadable", result[:cache_dirs_failure]
        assert_not result.key?(:cache_dirs)
      end
    end
  end

  test "the cache walk script fails on a missing root, a newline in a name, and finds tags at any depth" do
    Dir.mktmpdir do |dir|
      deep = File.join(dir, "work", *Array.new(10) { |i| "d#{i}" }, "target")
      FileUtils.mkdir_p(deep)
      File.write(File.join(deep, "CACHEDIR.TAG"), "Signature: 8a477f597d28d172789f06886806bc55\n")
      run = ->(*roots) { Open3.capture2("sh", "-c", Agents::StorageUsage::CACHE_SCRIPT, "cache-dirs", *roots) }

      out, status = run.call(File.join(dir, "work"))
      assert status.success?
      assert_match %r{\A\d+\t#{Regexp.escape(deep)}\n\z}, out

      _, status = run.call(File.join(dir, "work"), File.join(dir, "missing"))
      assert_not status.success?, "a missing root must fail the walk, not drop out of it"

      odd = File.join(dir, "work", "odd\nname")
      FileUtils.mkdir_p(odd)
      File.write(File.join(odd, "CACHEDIR.TAG"), "")
      _, status = run.call(File.join(dir, "work"))
      assert_not status.success?, "a newline in a tag path must fail the walk"
    end
  end

end
