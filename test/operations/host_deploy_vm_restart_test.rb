require "test_helper"

# ops/deploy/roll-vm-resident.rb: the deploy's restart of a resident whose
# container is on its own VM. It goes through the runner, pinned by image ID,
# between turns only, and holds turns until the runner confirms that image.
class HostDeployVmRestartTest < ActiveJob::TestCase

  RUNNING = "sha256:#{'1' * 64}".freeze
  BUILT = "sha256:#{'2' * 64}".freeze
  KEYS = %w[DEPLOY_RESIDENT_ID DEPLOY_VM_MODE DEPLOY_RESIDENT_IMAGE DEPLOY_RESIDENT_IMAGE_ID
            DEPLOY_VM_COMMAND_ID SOULSHOUSE_DOMAIN].freeze

  setup do
    @previous_env = ENV.to_h.slice(*KEYS)
    ENV["SOULSHOUSE_DOMAIN"] = "souls.example"
    @agent = agents(:research_assistant)
    @agent.update!(runtime: "external", container_name: "hk-agent-vm-deploy", container_image: "stock:old",
      trigger_bearer_token: "trig", runtime_ready_at: Time.current, uuid: SecureRandom.uuid_v7)
    @placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 4242)
    @enrollment, token = RunnerEnrollment.mint!(placement: @placement)
    @enrollment.confirm_provider_server!(4242)
    @enrollment.enroll!(token:, public_key: Base64.strict_encode64("k" * 32), reported_server_id: 4242, facts: {},
      nonce: SecureRandom.hex(16))
    @enrollment.heartbeat!(reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
    answer(RunnerCommand.enqueue!(enrollment: @enrollment, kind: "start_resident", payload: { "image" => RUNNING }),
      "done", RUNNING)
    ENV["DEPLOY_RESIDENT_ID"] = @agent.id.to_s
  end

  teardown do
    KEYS.each { |key| @previous_env.key?(key) ? ENV[key] = @previous_env[key] : ENV.delete(key) }
  end

  def answer(command, outcome, image = nil)
    command.deliver!(now: Time.current)
    result = { "outcome" => outcome }
    result["result"] = { "state" => "running", "image" => image } if image
    result["error"] = "boom" unless outcome == "done"
    command.record_result!(result, now: Time.current)
  end

  def run_script(mode, built: BUILT, **env)
    ENV["DEPLOY_VM_MODE"] = mode
    ENV["DEPLOY_RESIDENT_IMAGE"] = "stock:deploy-fixture"
    ENV["DEPLOY_RESIDENT_IMAGE_ID"] = BUILT
    env.each { |key, value| ENV[key.to_s] = value.to_s }
    output = nil
    ResidentTurn.stub(:enabled?, true) do
      Agents::RemoteRuntime.stub(:local_image_id, built) do
        output, = capture_io { load Rails.root.join("ops/deploy/roll-vm-resident.rb") }
      end
    end
    JSON.parse(output.lines.last)
  end

  def started
    run_script("start").tap { |result| assert_equal "started", result.fetch("result") }
  end

  def restart_command(result) = RunnerCommand.find(result.fetch("command_id"))

  test "inspect reports the image the runner last confirmed" do
    result = run_script("inspect")
    assert result.fetch("running")
    assert_equal RUNNING, result.fetch("image")
  end

  test "inspect says unreachable when the runner has gone quiet" do
    @enrollment.update_columns(last_heartbeat_at: 1.hour.ago)
    result = run_script("inspect")
    assert_not result.fetch("running")
    assert_nil result.fetch("image")
    assert_equal "unavailable", run_script("start").fetch("result")
    assert_equal "stock:old", @agent.reload.container_image
  end

  test "a pending turn leaves the resident, its image and the queue unchanged" do
    interaction = AgentRuntimeInteraction.create!(agent: @agent, trigger_kind: "wake", session_id: "fixture-session",
      started_at: Time.current, endpoint_url: "runner://#{@enrollment.public_id}")
    turn = ResidentTurn.stub(:enabled?, true) { ResidentTurn.enqueue!(interaction, { session_id: "fixture-session" }) }
    assert_no_difference -> { RunnerCommand.count } do
      assert_equal "busy", run_script("start").fetch("result")
    end
    assert_equal "queued", turn.reload.state
    assert_equal "stock:old", @agent.reload.container_image
    assert_nil @placement.reload.refresh_command_id
  end

  test "start queues the built image by ID and holds turns until it settles" do
    command = restart_command(started)
    assert_equal "start_resident", command.kind
    assert_equal BUILT, JSON.parse(command.payload_json)["image"]
    assert_equal "stock:deploy-fixture", @agent.reload.container_image
    assert_equal command.id, @placement.reload.refresh_command_id
    assert Agents::RemoteRuntime.refresh_pending?(@agent)
  end

  test "a tag that resolves to another image sends nothing and changes nothing" do
    assert_no_difference -> { RunnerCommand.count } do
      assert_raises(RuntimeError) { run_script("start", built: RUNNING) }
    end
    assert_equal "stock:old", @agent.reload.container_image
    assert_nil @placement.reload.refresh_command_id
  end

  test "healthy only once the runner confirms the new image, and turns open again" do
    result = started
    command = restart_command(result)
    assert_equal "pending", run_script("status", DEPLOY_VM_COMMAND_ID: command.id).fetch("result")
    answer(command, "done", BUILT)
    assert_equal "healthy", run_script("status", DEPLOY_VM_COMMAND_ID: command.id).fetch("result")
    assert_not Agents::RemoteRuntime.refresh_pending?(@agent)
    assert_equal "current", run_script("start").fetch("result")
  end

  test "a done answer naming another image is not healthy" do
    command = restart_command(started)
    answer(command, "done", RUNNING)
    assert_equal "failed", run_script("status", DEPLOY_VM_COMMAND_ID: command.id).fetch("result")
  end

  test "a failed restart gets one recovery; a second failure keeps turns held" do
    command = restart_command(started)
    answer(command, "failed")
    assert_equal "pending", run_script("status", DEPLOY_VM_COMMAND_ID: command.id).fetch("result")
    recovery = RunnerCommand.find(@placement.reload.refresh_command_id)
    assert_equal BUILT, JSON.parse(recovery.payload_json)["image"]
    answer(recovery, "failed")
    assert_equal "failed", run_script("status", DEPLOY_VM_COMMAND_ID: command.id).fetch("result")
    assert Agents::RemoteRuntime.refresh_pending?(@agent)
  end

  test "status only answers for this resident's own command" do
    other = AgentPlacement.create!(agent: agents(:code_reviewer), backend: "hetzner_cloud", state: "ready",
      provider_server_id: 4343)
    enrollment, = RunnerEnrollment.mint!(placement: other)
    foreign = RunnerCommand.enqueue!(enrollment:, kind: "stop_resident", payload: {})
    assert_raises(RuntimeError) { run_script("status", DEPLOY_VM_COMMAND_ID: foreign.id) }
  end

end
