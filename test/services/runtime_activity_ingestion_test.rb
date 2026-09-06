require "test_helper"
require "action_cable/test_helper"

class RuntimeActivityIngestionTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  setup do
    @agent = agents(:research_assistant)
    @chat = @agent.account.chats.create!(title: "Activity", manual_responses: true, agents: [ @agent ])
    @run = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat)
    @run.claim_dispatch!
    @configuration = @run.activity_configuration!
    @attempt_id = SecureRandom.uuid
  end

  test "reservation prevents duplicate dispatch and can only be claimed once" do
    assert_not @run.claim_dispatch!
    assert_raises(ArgumentError) { AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat) }
    assert @chat.agent_response_active?(@agent)
  end

  test "pre-send errors fail immediately while post-send errors remain uncertain" do
    [ Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError, Net::OpenTimeout ].each do |klass|
      @run.update!(execution_state: "preparing", finished_at: nil)
      @run.record_error!(klass.new("synthetic"))
      assert_equal "failed", @run.reload.execution_state
      assert @run.finished_at?
    end
    [ Net::ReadTimeout, EOFError, Errno::ECONNRESET ].each do |klass|
      @run.update!(execution_state: "preparing", finished_at: nil)
      @run.record_error!(klass.new("synthetic"))
      assert_equal "preparing", @run.reload.execution_state
      assert_nil @run.finished_at
    end
    @run.update!(activity_token_digest: nil)
    @run.record_error!(RuntimeError.new("Docker startup failed"))
    assert_equal "failed", @run.reload.execution_state
    assert_not @chat.agent_response_active?(@agent)
  end

  test "ordinary activity reads do not acquire a write lock" do
    @run.stub(:with_lock, ->(*) { flunk "unnecessary write lock" }) { @run.reconcile_activity! }
  end

  test "slow preparation cannot send a trigger after its budget expires" do
    @run.update!(activity_token_digest: nil, execution_deadline_at: 1.second.ago)
    assert_raises(ArgumentError) { @run.activity_configuration! }
    assert_nil @run.reload.activity_token_digest
  end

  test "heartbeat repairs missing tool finish detail without inventing history" do
    ingest(1, "attempt.started", { "narration_capability" => "unknown" })
    ingest(2, "tool.started", { "operation_id" => "a", "category" => "tool" })
    ingest(4, "heartbeat", { "operations" => [], "detail_dropped" => 1 })
    assert_empty @run.as_chat_activity_json[:snapshot]["operations"]
    assert_equal 1, @run.as_chat_activity_json[:detail_dropped]
    assert_equal 2, @run.agent_runtime_attempts.first.agent_runtime_events.count
  end

  test "attempt registration requires its start before accepting detail" do
    assert_raises(RuntimeActivityIngestion::Invalid) { ingest(3, "heartbeat") }
    assert_empty @run.agent_runtime_attempts
  end

  test "delayed first callback can fill history after the synchronous result" do
    @run.record_result!(status: 200, body: { "status" => "ok" })
    ingest(1, "attempt.started", { "narration_capability" => "unknown" })
    ingest(2, "turn.started")
    assert_equal "completed", @run.reload.execution_state
    assert_equal 200, @run.transport_status
    assert_equal 2, @run.agent_runtime_attempts.first.agent_runtime_events.count
  end

  test "proxy errors cannot claim execution stopped and a late supervisor can settle it" do
    @run.record_result!(status: 504, body: { "raw" => "Gateway timeout" })
    assert_nil @run.reload.finished_at
    assert_equal "preparing", @run.execution_state
    ingest(1, "attempt.started", { "narration_capability" => "unknown" })
    ingest(2, "supervisor.finished", { "outcome" => "completed", "runtime_status" => "ok" })
    assert_equal "completed", @run.reload.execution_state
    assert_equal 504, @run.transport_status
  end

  test "callbacks are scoped and expire without granting general API access" do
    assert @run.valid_activity_token?(@configuration[:token])
    assert_not @run.valid_activity_token?("wrong")
    assert_nil ApiKey.authenticate(@configuration[:token])
    @agent.update_columns(runtime: "deprecated")
    assert_not @run.valid_activity_token?(@configuration[:token])
    @agent.update_columns(runtime: "external")
    @chat.chat_agents.delete_all
    assert_not @run.valid_activity_token?(@configuration[:token])
  end

  test "safe events project live tools without raw arguments or diagnostic content" do
    ingest(1, "attempt.started", { "narration_capability" => "unsupported" })
    ingest(2, "turn.started")
    ingest(3, "tool.started", {
      "operation_id" => "tool-1", "category" => "command", "command" => "SECRET", "output" => "SECRET"
    })
    assert_equal "running", @run.reload.execution_state
    public_json = @run.as_chat_activity_json
    assert_equal "Run a command", public_json[:snapshot]["operations"]["tool-1"]["label"]
    assert_not_includes public_json.to_json, "SECRET"
    assert_not public_json.key?(:stdout)
    ingest(4, "tool.finished", { "operation_id" => "tool-1", "category" => "command", "outcome" => "failed" })
    assert_equal({}, @run.as_chat_activity_json[:snapshot]["operations"])
    assert_equal "running", @run.reload.execution_state
  end

  test "duplicate delivery is idempotent and conflicting payload is rejected" do
    ingest(1, "attempt.started", { "narration_capability" => "unknown" })
    assert_no_difference "AgentRuntimeEvent.count" do
      ingest(1, "attempt.started", { "narration_capability" => "unknown" })
    end
    assert_raises(RuntimeActivityIngestion::Invalid) do
      ingest(1, "attempt.started", { "narration_capability" => "supported" })
    end
  end

  test "command previews are independently validated in detail and heartbeat snapshots" do
    ingest(1, "attempt.started", { "narration_capability" => "unknown" })
    operation = { "operation_id" => "cmd", "category" => "command", "command_preview" => "git status --short" }
    ingest(2, "tool.started", operation)
    assert_equal "git status --short", @run.as_chat_activity_json[:snapshot]["operations"]["cmd"]["label"]
    ingest(3, "heartbeat", { "operations" => [ operation.merge("command_preview" => "curl [arguments hidden]") ] })
    assert_equal "curl [arguments hidden]", @run.as_chat_activity_json[:snapshot]["operations"]["cmd"]["label"]
    ingest(4, "tool.finished", operation.merge("outcome" => "completed"))
    assert_equal "git status --short", @run.agent_runtime_attempts.first.agent_runtime_events.last.data["label"]
    ingest(5, "tool.started", operation.merge("command_preview" => "curl --token SECRET"))
    assert_equal "Run a command", @run.as_chat_activity_json[:snapshot]["operations"]["cmd"]["label"]
    assert_not_includes @run.as_chat_activity_json.to_json, "SECRET"
    assert_not_includes @run.agent_runtime_attempts.first.agent_runtime_events.pluck(:data).to_json, "SECRET"
  end

  test "out of order events cannot resurrect a finished tool" do
    ingest(1, "attempt.started", { "narration_capability" => "unknown" })
    ingest(3, "tool.finished", { "operation_id" => "a", "category" => "tool", "outcome" => "completed" })
    ingest(2, "tool.started", { "operation_id" => "a", "category" => "tool" })
    assert_equal({}, @run.as_chat_activity_json[:snapshot]["operations"])
  end

  test "fallback requires a transition and old attempts cannot finish current run" do
    ingest(1, "attempt.started", { "narration_capability" => "unknown" })
    second = SecureRandom.uuid
    assert_raises(RuntimeActivityIngestion::Invalid) do
      ingest(1, "attempt.started", { "narration_capability" => "unknown" }, attempt_id: second, number: 2)
    end
    ingest(2, "fallback")
    ingest(1, "attempt.started", { "narration_capability" => "unknown" }, attempt_id: second, number: 2)
    ingest(3, "supervisor.finished", { "outcome" => "failed" })
    assert_not @run.reload.finished_at
  end

  test "resident narration consent is required and revocation suppresses new text" do
    ingest(1, "attempt.started", { "narration_capability" => "supported" })
    ingest(2, "commentary.completed", { "text" => "Not shared" })
    assert_not_includes @run.as_chat_activity_json.to_json, "Not shared"
    @agent.update!(share_working_narration: true)
    @run.update!(narration_shared: true)
    ingest(3, "commentary.completed", { "text" => "Shared update" })
    assert_equal "Shared update", @run.as_chat_activity_json[:snapshot]["commentary"]
    @agent.update!(share_working_narration: false)
    result = ingest(4, "commentary.completed", { "text" => "Revoked" })
    assert_equal false, result[:share_narration]
    assert_not_includes @run.as_chat_activity_json.to_json, "Revoked"
  end

  test "terminal callback recovers accounting without fabricating successful transport" do
    ingest(1, "attempt.started", { "narration_capability" => "unknown" })
    ingest(2, "supervisor.finished", {
      "outcome" => "completed", "runtime_status" => "ok", "returncode" => 0,
      "telemetry" => {
        "schema_version" => 1, "session" => { "chaos_process_id" => "session-1" },
        "usage" => { "scope" => "invocation", "input_tokens" => 5, "output_tokens" => 2, "complete" => true }
      }
    })
    assert_equal "completed", @run.reload.execution_state
    assert_nil @run.transport_status
    assert_equal 5, @run.input_tokens
    assert_equal "session-1", @run.chaos_session_id
    request = ExternalAgentResponseRequest.new(agent: @agent, chat: @chat)
    assert_nil request.send(:prior_cursor_message_id)
    assert @run.visible_in_chat_timeline?
  end

  test "heartbeats do not trigger whole interaction refresh fan out" do
    ingest(1, "attempt.started", { "narration_capability" => "unknown" })
    assert_no_broadcasts("Agent:#{@agent.to_param}") { ingest(2, "heartbeat") }
    assert_equal "live", @run.as_chat_activity_json[:reporter_health]
  end

  test "deadline and grace release an unknown run without pretending it stopped" do
    @run.update!(execution_deadline_at: 11.minutes.ago)
    @run.reconcile_activity!
    assert_equal "outcome_unknown", @run.execution_state
    assert_not @chat.agent_response_active?(@agent)
    replacement = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat)
    assert_equal "queued", replacement.execution_state
  end

  test "live reports hold the reservation after a deadline" do
    ingest(1, "attempt.started", { "narration_capability" => "unknown" })
    @run.update!(execution_deadline_at: 11.minutes.ago)
    @run.reconcile_activity!
    assert_nil @run.finished_at
  end

  test "oversized unknown and malformed events are rejected" do
    ingest(1, "attempt.started", { "narration_capability" => "unknown" })
    assert_raises(RuntimeActivityIngestion::Invalid) { ingest(2, "reasoning", { "text" => "private" }) }
    assert_raises(RuntimeActivityIngestion::Invalid) { ingest(2, "commentary.completed", { "text" => "x" * 4_097 }) }
    assert_raises(RuntimeActivityIngestion::Invalid) { ingest(2, "tool.started", { "category" => "raw" }) }
  end

  test "bounded history preserves terminal state and reports omission" do
    ingest(1, "attempt.started", { "narration_capability" => "unknown" })
    @run.agent_runtime_attempts.first.update!(detail_count: 2_000)
    assert_no_difference "AgentRuntimeEvent.count" do
      ingest(2, "supervisor.finished", { "outcome" => "completed" })
    end
    assert_equal "completed", @run.reload.execution_state
    assert_operator @run.as_chat_activity_json[:detail_dropped], :>, 0
  end

  private

  def ingest(seq, type, data = {}, attempt_id: @attempt_id, number: 1)
    RuntimeActivityIngestion.new(@run, {
      "schema_version" => 1, "run_id" => @run.run_id,
      "attempt_id" => attempt_id, "attempt_number" => number,
      "events" => [ { "seq" => seq, "type" => type, "data" => data } ]
    }).call
  end

end
