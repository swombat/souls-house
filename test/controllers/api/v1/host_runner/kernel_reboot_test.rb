require "test_helper"
require_relative "../../../../support/runner_signing"

# Resident VMs reboot onto the kernel unattended-upgrades installed, only
# when the house sees the resident idle (4 Nov: Janis's VM ran 6.12.107 two
# days after 6.12.115 was installed).
class Api::V1::HostRunner::KernelRebootTest < ActionDispatch::IntegrationTest

  include RunnerSigning

  OLD = "6.12.107+deb13-amd64".freeze
  NEW = "6.12.115+deb13-amd64".freeze

  setup do
    @agent = agents(:research_assistant)
    @placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 4242)
    @enrollment, token = RunnerEnrollment.mint!(placement: @placement)
    @enrollment.confirm_provider_server!(4242)
    @key = runner_key
    @enrollment.enroll!(token:, public_key: public_key_b64(@key), reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
  end

  def beat(facts = {})
    body = { facts: { provider_server_id: 4242, runner_bundle_sha256: RunnerBundle.current.sha256 }.merge(facts) }.to_json
    path = "/api/v1/host_runner/heartbeat"
    post path, params: body, headers: signed_runner_headers(@key, path:, body:, runner_id: @enrollment.public_id)
      .merge("CONTENT_TYPE" => "application/json")
    assert_response :ok
  end

  def required(**extra)
    { kernel_running: OLD, kernel_installed: NEW, reboot_required: true, reboot_host: 1, uptime_seconds: 3 * 86_400,
      reboot_required_since: 1.hour.ago.to_i }.merge(extra)
  end

  def reboots = @enrollment.commands.where(kind: "reboot_host")

  def pending_turn(state: "queued")
    interaction = AgentRuntimeInteraction.create!(agent: @agent, trigger_kind: "wake", session_id: "s",
      started_at: Time.current, endpoint_url: "runner://#{@enrollment.public_id}")
    ResidentTurn.create!(agent: @agent, agent_runtime_interaction: interaction, dispatch_id: SecureRandom.uuid,
      session_id: "s", payload: "{}", state:)
  end

  def answer(command, outcome: "done", result: { "state" => "rebooting", "kernel_running" => OLD, "kernel_installed" => NEW })
    command.deliver!(now: Time.current)
    command.record_result!({ "outcome" => outcome, "result" => result, "error" => (outcome == "done" ? nil : "busy") }.compact,
      now: Time.current)
  end

  # --- the idle gate ---------------------------------------------------------

  test "idle and required: one reboot_host, with no arguments" do
    beat(required)
    assert_equal 1, reboots.count
    assert_equal({}, JSON.parse(reboots.last.payload_json))
    beat(required)
    assert_equal 1, reboots.count, "an open reboot is not queued twice"
  end

  test "busy with a pending turn: no reboot" do
    pending_turn
    beat(required)
    assert_equal 0, reboots.count
  end

  test "busy with a running turn: no reboot, then a reboot once it has finished" do
    turn = pending_turn(state: "running")
    beat(required)
    assert_equal 0, reboots.count
    turn.update!(state: "done", finished_at: Time.current)
    turn.agent_runtime_interaction.update!(finished_at: Time.current)
    beat(required)
    assert_equal 1, reboots.count
  end

  test "busy with another command in flight: no reboot" do
    RunnerCommand.enqueue!(enrollment: @enrollment, kind: "home_stats", payload: { "container_name" => "x" })
    beat(required)
    assert_equal 0, reboots.count
  end

  test "busy with an active interaction: no reboot" do
    AgentRuntimeInteraction.create!(agent: @agent, trigger_kind: "wake", started_at: Time.current)
    beat(required)
    assert_equal 0, reboots.count
  end

  test "not required: nothing" do
    beat(kernel_running: NEW, kernel_installed: NEW, reboot_required: false, reboot_host: 1)
    assert_equal 0, reboots.count
  end

  test "a runner that can't reboot is never asked" do
    beat(required.except(:reboot_host))
    assert_equal 0, reboots.count
  end

  test "a placement that isn't ready is never rebooted" do
    @placement.update_columns(state: "pending")
    beat(required)
    assert_equal 0, reboots.count
  end

  # --- retries ---------------------------------------------------------------

  test "a refused attempt is retried after a while, not on the next beat" do
    beat(required)
    answer(reboots.last, outcome: "refused", result: nil)
    beat(required)
    assert_equal 1, reboots.count
    travel 16.minutes do
      beat(required)
    end
    assert_equal 2, reboots.count
  end

  # --- after -----------------------------------------------------------------

  test "a turn arriving during the reboot waits, and is released by the fresh boot" do
    beat(required)
    assert_includes KernelReboot.holding_agent_ids, @agent.id, "held while the reboot is queued"
    answer(reboots.last)
    assert_includes KernelReboot.holding_agent_ids, @agent.id, "held while the VM hasn't come back"

    travel 2.minutes do
      assert_enqueued_with(job: ResidentTurnDispatchJob) do
        beat(kernel_running: NEW, kernel_installed: NEW, reboot_required: false, reboot_host: 1, uptime_seconds: 30)
      end
      assert_not_includes KernelReboot.holding_agent_ids, @agent.id
    end
  end

  test "turn admission keeps a held resident's turn queued" do
    turn = pending_turn
    KernelReboot.stub(:holding_agent_ids, Set[@agent.id]) do
      assert_not_includes ResidentTurn.admit!, turn.id
    end
    assert_equal "queued", turn.reload.state
  end

  test "the fresh boot is recorded once and the owner told once, with the new kernel" do
    beat(required)
    answer(reboots.last)
    beat(required(uptime_seconds: 3 * 86_400))
    assert_equal 0, AuditLog.where(action: KernelReboot::RECORDED).count, "no boot seen yet"

    travel 2.minutes do
      assert_difference -> { @agent.account.chats.count }, 1 do
        beat(kernel_running: NEW, kernel_installed: NEW, reboot_required: false, reboot_host: 1, uptime_seconds: 40)
        beat(kernel_running: NEW, kernel_installed: NEW, reboot_required: false, reboot_host: 1, uptime_seconds: 100)
      end
    end
    audit = AuditLog.find_by!(action: KernelReboot::RECORDED)
    assert_equal({ "kernel_before" => OLD, "kernel_after" => NEW }, audit.data.slice("kernel_before", "kernel_after"))
    line = Chat.find(audit.data["chat_id"]).messages.last
    assert_equal "system", line.role
    assert_includes line.content, "restarted for a kernel update"
    assert_includes line.content, "back on Linux #{NEW}"
  end

  test "a reboot that never came back is tried again after the grace" do
    beat(required)
    answer(reboots.last)
    beat(required)
    assert_equal 1, reboots.count
    travel 16.minutes do
      beat(required)
    end
    assert_equal 2, reboots.count
  end

  test "kernel facts are shape-checked before they are stored" do
    beat(required(kernel_running: "6.12; rm -rf /", reboot_required: "yes", reboot_host: true))
    facts = @enrollment.reload.last_facts
    assert_nil facts["kernel_running"]
    assert_nil facts["reboot_required"]
    assert_nil facts["reboot_host"]
    assert_equal NEW, facts["kernel_installed"]
    assert_equal 0, reboots.count
  end

end
