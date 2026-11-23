require "test_helper"
require "tmpdir"

# A VM resident's disk figure (#1111): walked by its runner, kept apart from
# the house host's storage_usage.
class Agents::HomeStorageTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "external", container_name: "test-resident", home_storage: {})
  end

  def vm!(version: Agents::RemoteRuntime::HOME_STATS_VERSION)
    placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 4343)
    enrollment, token = RunnerEnrollment.mint!(placement:)
    enrollment.confirm_provider_server!(4343)
    enrollment.enroll!(token:, public_key: Base64.strict_encode64("k" * 32), reported_server_id: 4343, facts: {},
                       nonce: SecureRandom.hex(16))
    enrollment.update!(last_facts: { "home_stats" => version })
    @agent.reload
    enrollment
  end

  def measure(answer)
    relay = answer.is_a?(Proc) ? answer : ->(*, **) { answer }
    Agents::RemoteRuntime.stub(:relay!, relay) { Agents::HomeStorage.new(@agent).call }
  end

  test "a resident on the house host is never walked here" do
    Agents::RemoteRuntime.stub(:relay!, ->(*, **) { flunk "must not ask a runner" }) do
      assert_equal [ "unavailable", "failed" ], Agents::HomeStorage.new(@agent).call.values_at("status", "reason")
    end
  end

  test "the runner's walk is the card's size, asked for as part storage" do
    vm!
    asked = []
    storage = measure(lambda do |agent, kind, payload, **|
      asked << [ agent.id, kind, payload ]
      { "storage_bytes" => 89_003_048_960 }
    end)
    assert_equal [ "measured", 89_003_048_960 ], storage.values_at("status", "bytes")
    assert_equal storage["measured_at"], storage["attempted_at"]
    assert_equal [ [ @agent.id, "home_stats", { "container_name" => "test-resident", "part" => "storage" } ] ], asked
  end

  test "a walk out of time is too slow, keeping an earlier size as stale" do
    vm!
    assert_equal [ "too_slow", nil ], measure({ "error" => "timeout" }).values_at("status", "bytes")

    earlier = 2.hours.ago.iso8601
    @agent.home_storage = { "status" => "measured", "bytes" => 1024, "measured_at" => earlier }
    storage = measure({ "error" => "timeout" })
    assert_equal [ "too_slow", 1024, earlier ], storage.values_at("status", "bytes", "measured_at")
    assert_operator Time.iso8601(storage["attempted_at"]), :>, Time.iso8601(earlier)
  end

  test "an old runner is not asked, and a failed or unreadable answer is unavailable, never zero" do
    vm!(version: 2)
    storage = measure(->(*, **) { flunk "an old runner must not be asked" })
    assert_equal [ "unavailable", "runner_too_old" ], storage.values_at("status", "reason")

    RunnerEnrollment.update_all(last_facts: { "home_stats" => Agents::RemoteRuntime::HOME_STORAGE_VERSION })
    @agent.home_storage = { "status" => "measured", "bytes" => 1024, "measured_at" => 1.day.ago.iso8601 }
    [ { "error" => "failed" }, { "storage_bytes" => -1 }, { "storage_bytes" => "12" }, "nonsense",
      ->(*, **) { raise Agents::RemoteRuntime::Unavailable, "did not answer" } ].each do |answer|
      storage = measure(answer)
      assert_equal [ "unavailable", "failed", 1024 ], storage.values_at("status", "reason", "bytes"), answer.inspect
    end
  end

  # The script itself, pointed at scratch volumes.
  def walk(home, budget = "25")
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

  test "the runner carries the house's walk byte for byte" do
    runner = Rails.root.join("host-runner/souls_house_runner.py").read
    copy = runner[/^HOME_STORAGE_SCRIPT = r"""(.*?)"""/m, 1]
    assert copy, "the runner defines HOME_STORAGE_SCRIPT"
    assert_equal Agents::HomeStorage::SCRIPT, copy
  end

  # Mira on #1111: a VM that was offline must not come back to a queue of
  # measurements nobody is waiting for, ahead of its next turn.
  test "a walk the house stopped waiting for is never delivered; the next command is" do
    enrollment = vm!
    2.times do
      assert_raises(Agents::RemoteRuntime::Unavailable) { Agents::RemoteRuntime.home_storage!(@agent, wait: 0, poll: 0) }
    end
    assert_raises(Agents::RemoteRuntime::Unavailable) { Agents::RemoteRuntime.home_stats!(@agent, wait: 0, poll: 0) }
    walks = RunnerCommand.where(kind: "home_stats")
    assert_equal [ "refused" ] * 3, walks.pluck(:state)
    assert walks.all? { |command| command.payload_json.nil? }

    turn = RunnerCommand.enqueue!(enrollment:, kind: "turn_status", payload: { "dispatch_id" => "x" })
    assert_equal turn, RunnerCommand.next_for(enrollment, now: Time.current)
  end

  test "a walk the runner already took is left to finish when the house stops waiting" do
    placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 4343)
    enrollment, = RunnerEnrollment.mint!(placement:)
    command = RunnerCommand.enqueue!(enrollment:, kind: "home_stats", payload: { "part" => "storage" })
    command.deliver!(now: Time.current)
    assert_not command.abandon_if_queued!(now: Time.current)
    assert_equal "delivered", command.reload.state
  end

end
