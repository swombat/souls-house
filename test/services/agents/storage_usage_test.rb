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

end
