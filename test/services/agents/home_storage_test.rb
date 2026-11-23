require "test_helper"
require "tmpdir"

class Agents::HomeStorageTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "external", container_name: "test-resident", home_storage: {})
    @service = Agents::HomeStorage.new(@agent)
    @resources = Struct.new(:verify_existing!).new(true)
  end

  def measure(stdout, ok: true)
    Agents::Resources.stub(:new, @resources) do
      @service.stub(:capture, { ok:, stdout: }) { @service.call }
    end
  end

  test "a finished walk is the card's size" do
    storage = measure("noise\n{\"storage_bytes\": 89003048960}")
    assert_equal "measured", storage["status"]
    assert_equal 89_003_048_960, storage["bytes"]
    assert_equal storage["measured_at"], storage["attempted_at"]
  end

  # Mira's 122 GB home took 17 s against the old 10 s (jZWPXJ): a walk that
  # runs out of time says so, and keeps the last size it had, not a dash.
  test "a walk out of time is too slow, keeping an earlier size as stale" do
    storage = measure('{"error": "timeout"}')
    assert_equal "too_slow", storage["status"]
    assert_nil storage["bytes"]

    earlier = 2.hours.ago.iso8601
    @agent.home_storage = { "status" => "measured", "bytes" => 1024, "measured_at" => earlier }
    storage = measure('{"error": "timeout"}')
    assert_equal [ "too_slow", 1024, earlier ], storage.values_at("status", "bytes", "measured_at")
    assert_operator Time.iso8601(storage["attempted_at"]), :>, Time.iso8601(earlier)
  end

  test "a failed or unreadable walk is unavailable, never zero, and nothing of the output is kept" do
    @agent.home_storage = { "status" => "measured", "bytes" => 1024, "measured_at" => 1.day.ago.iso8601 }
    [ [ "private prose", true ], [ '{"error": "failed"}', true ], [ '{"storage_bytes": -1}', true ],
      [ '{"storage_bytes": "12"}', true ], [ "[1]", true ], [ "", true ], [ '{"storage_bytes": 1}', false ] ].each do |stdout, ok|
      storage = measure(stdout, ok:)
      assert_equal [ "unavailable", "failed", 1024 ], storage.values_at("status", "reason", "bytes"), stdout
      assert_not_includes storage.to_json, "private prose"
    end
  end

  test "foreign residents and missing containers are never walked" do
    @service.stub(:capture, -> { flunk "must not execute" }) do
      @agent.container_name = nil
      assert_equal "unavailable", @service.call["status"]
      @agent.container_name = "test"
      @agent.sandbox_host = "foreign-host"
      assert_equal "unavailable", @service.call["status"]
    end
  end

  test "the walk's budget goes in as one argv value" do
    argv = nil
    popen = lambda do |*args, **|
      argv = args
      { ok: true, stdout: '{"storage_bytes": 5}' }
    end
    Agents::Resources.stub(:new, @resources) do
      Open3.stub(:popen3, popen) { assert_equal 5, @service.call["bytes"] }
    end
    assert_equal [ "test-resident", "timeout", Agents::HomeStorage::EXEC_SECONDS.to_s,
                   "python3", "-c", Agents::HomeStorage::SCRIPT, Agents::HomeStorage::DU_SECONDS.to_s ], argv.drop(2)
  end

  # The script itself, pointed at scratch volumes.
  def walk(home, budget = "150")
    script = Agents::HomeStorage::SCRIPT
    roots = '"/home/agent/" + name'
    raise "the walk's volume roots moved" unless script.include?(roots)
    script = script.sub(roots, "#{home.to_s.inspect} + \"/\" + name")
    stdout, stderr, status = Open3.capture3("python3", "-c", script, budget)
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  test "the script sums all five volumes and returns only the total" do
    Dir.mktmpdir do |home|
      %w[identity .chaos repo work state].each { |name| FileUtils.mkdir_p(File.join(home, name)) }
      File.write(File.join(home, "work", "big"), "x" * 200_000)
      File.write(File.join(home, "identity", ".hidden"), "private prose")
      answer = walk(home)
      assert_equal [ "storage_bytes" ], answer.keys
      assert_operator answer["storage_bytes"], :>=, 200_000
    end
  end

  test "the script refuses a linked volume root and a missing one" do
    Dir.mktmpdir do |home|
      %w[identity .chaos repo work].each { |name| FileUtils.mkdir_p(File.join(home, name)) }
      assert_equal({ "error" => "failed" }, walk(home))
      File.symlink(File.join(home, "work"), File.join(home, "state"))
      assert_equal({ "error" => "failed" }, walk(home))
    end
  end

  test "a VM resident is walked by its runner, never by a local docker exec, and an old runner is not asked" do
    placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 4343)
    enrollment, token = RunnerEnrollment.mint!(placement:)
    enrollment.confirm_provider_server!(4343)
    enrollment.enroll!(token:, public_key: Base64.strict_encode64("k" * 32), reported_server_id: 4343, facts: {},
                       nonce: SecureRandom.hex(16))
    enrollment.update!(last_facts: { "home_stats" => 2 })
    @agent.reload
    service = Agents::HomeStorage.new(@agent)

    asked = []
    relay = lambda do |agent, kind, payload, **|
      asked << [ agent.id, kind, payload ]
      { "storage_bytes" => 2048 }
    end
    Agents::RemoteRuntime.stub(:relay!, relay) do
      service.stub(:capture, -> { flunk "must not docker exec on the house host" }) do
        storage = service.call
        assert_equal [ "unavailable", "runner_too_old" ], storage.values_at("status", "reason")
        assert_empty asked

        enrollment.update!(last_facts: { "home_stats" => Agents::RemoteRuntime::HOME_STORAGE_VERSION })
        assert_equal [ "measured", 2048 ], service.call.values_at("status", "bytes")
      end
    end
    assert_equal [ [ @agent.id, "home_stats", { "container_name" => "test-resident", "part" => "storage" } ] ], asked

    Agents::RemoteRuntime.stub(:relay!, ->(*, **) { { "error" => "timeout" } }) do
      assert_equal "too_slow", service.call["status"]
    end
    Agents::RemoteRuntime.stub(:relay!, ->(*, **) { raise Agents::RemoteRuntime::Unavailable, "did not answer" }) do
      assert_equal [ "unavailable", "failed" ], service.call.values_at("status", "reason")
    end
  end

  test "the runner carries the house's walk byte for byte" do
    runner = Rails.root.join("host-runner/souls_house_runner.py").read
    copy = runner[/^HOME_STORAGE_SCRIPT = r"""(.*?)"""/m, 1]
    assert copy, "the runner defines HOME_STORAGE_SCRIPT"
    assert_equal Agents::HomeStorage::SCRIPT, copy
  end

end
