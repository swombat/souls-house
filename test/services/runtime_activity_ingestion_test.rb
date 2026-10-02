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

  test "execution deadline follows resident budget without doubling it for resume" do
    freeze_time do
      @agent.update!(turn_timeout_minutes: 1440)
      @run.activity_configuration!
      assert_equal 86430.seconds.from_now, @run.reload.execution_deadline_at
      assert_operator @run.activity_token_expires_at, :>, @run.execution_deadline_at
    end
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
    ingest(3, "heartbeat", { "operations" => [ operation.merge("command_preview" => "cat app/models/agent.rb") ] })
    assert_equal "cat app/models/agent.rb", @run.as_chat_activity_json[:snapshot]["operations"]["cmd"]["label"]
    ingest(4, "tool.finished", operation.merge("outcome" => "completed"))
    assert_equal "git status --short", @run.agent_runtime_attempts.first.agent_runtime_events.last.data["label"]
    ingest(5, "tool.started", operation.merge("command_preview" => "curl --token SECRET"))
    assert_equal "curl --token [REDACTED]", @run.as_chat_activity_json[:snapshot]["operations"]["cmd"]["label"]
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
    @agent.update!(share_working_narration: false)
    @run.update!(narration_shared: false)
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

  test "helper completion and reactivation retain run ordinals and stable ordering" do
    start_helpers
    ingest(2, "agent.status_changed", helper)
    ingest(3, "agent.status_changed", helper.merge("child_process_id" => "private-child-2", "status" => "pending_init"))
    ingest(4, "agent.status_changed", helper.merge("status" => "completed"))
    assert_equal [ 1, 2 ], helper_snapshot["subagents"].map { |child| child["ordinal"] }
    assert_equal %w[completed pending_init], helper_snapshot["subagents"].map { |child| child["status"] }
    ingest(5, "agent.status_changed", helper)
    assert_equal %w[running pending_init], helper_snapshot["subagents"].map { |child| child["status"] }
    ingest(6, "agent.status_changed", helper.merge("status" => "completed"))
    ingest(7, "supervisor.finished", { "outcome" => "completed" })
    assert_equal %w[completed unknown], helper_snapshot["subagents"].map { |child| child["status"] }
  end

  test "source attachments and explicit gaps invalidate active children until fresh lifecycle" do
    start_helpers
    ingest(2, "agent.status_changed", helper)
    ingest(3, "stream.started")
    assert_equal "unknown", helper_snapshot["subagents"].first["status"]
    ingest(4, "heartbeat", { "subagents" => [ helper.merge("status" => "completed") ] })
    assert_equal "unknown", helper_snapshot["subagents"].first["status"]
    ingest(5, "agent.status_changed", helper)
    assert_equal "running", helper_snapshot["subagents"].first["status"]
    ingest(6, "stream.gap")
    ingest(7, "heartbeat", { "subagents" => [ helper ] })
    assert_equal "unknown", helper_snapshot["subagents"].first["status"]
    ingest(8, "agent.status_changed", helper.merge("status" => "completed"))
    assert_equal "completed", helper_snapshot["subagents"].first["status"]
  end

  test "sequence omissions and reporting silence persist unknown across heartbeats" do
    start_helpers
    ingest(2, "agent.status_changed", helper)
    ingest(4, "heartbeat", { "subagents" => [ helper ] })
    assert_equal "unknown", helper_snapshot["subagents"].first["status"]
    ingest(5, "agent.status_changed", helper)
    travel 31.seconds do
      assert_equal "unknown", helper_snapshot["subagents"].first["status"]
      ingest(6, "heartbeat", { "subagents" => [ helper ] })
      assert_equal "unknown", helper_snapshot["subagents"].first["status"]
      assert_equal "live", @run.as_chat_activity_json[:reporter_health]
    end
  end

  test "restarted reporter cannot reuse attempt admission or imply replay of active children" do
    start_helpers
    ingest(2, "agent.status_changed", helper)
    assert_raises(RuntimeActivityIngestion::Invalid) do
      ingest(1, "attempt.started", { "narration_capability" => "unknown" }, attempt_id: SecureRandom.uuid)
    end
    travel 31.seconds do
      assert_equal "unknown", helper_snapshot["subagents"].first["status"]
    end
  end

  test "fallback preserves ordinals and marks prior active children unknown" do
    start_helpers
    ingest(2, "agent.status_changed", helper)
    ingest(3, "fallback")
    assert_equal "unknown", helper_snapshot["subagents"].first["status"]
    second = SecureRandom.uuid
    ingest(1, "attempt.started", { "narration_capability" => "unknown" }, attempt_id: second, number: 2)
    ingest(2, "agent.status_changed", helper.merge("child_process_id" => "private-child-2"), attempt_id: second, number: 2)
    assert_equal [ 1, 2 ], helper_snapshot["subagents"].map { |child| child["ordinal"] }
    assert_equal %w[unknown running], helper_snapshot["subagents"].map { |child| child["status"] }
    ingest(4, "agent.status_changed", helper.merge("status" => "completed"))
    assert_equal "unknown", helper_snapshot["subagents"].first["status"]
  end

  test "helper overflow counts distinct identities not repeated transitions" do
    start_helpers
    34.times { |index| ingest(index + 2, "agent.status_changed", helper.merge("child_process_id" => "private-child-#{index}")) }
    ingest(36, "agent.status_changed", helper.merge("child_process_id" => "private-child-33", "status" => "completed"))
    assert_equal 32, helper_snapshot["subagents"].size
    assert_equal 2, helper_snapshot["subagents_overflow"]
    assert_not helper_snapshot["subagents_overflow_capped"]
    assert_equal (1..32).to_a, helper_snapshot["subagents"].map { |child| child["ordinal"] }
  end

  test "ingestion and browser and native projections do not expose kernel ids roles or private payloads" do
    start_helpers
    ingest(2, "agent.status_changed", helper.merge("agent_role" => "PRIVATE_ROLE", "prompt" => "PRIVATE_PROMPT",
      "result" => "PRIVATE_RESULT", "error" => { "message" => "PRIVATE_ERROR" }))
    attempt = @run.agent_runtime_attempts.first
    assert_equal "Helper", helper_snapshot["subagents"].first["nickname"]
    assert_equal %w[model nickname ordinal status], helper_snapshot["subagents"].first.keys.sort
    assert_equal %w[model nickname ordinal status], attempt.agent_runtime_events.last.data.keys.sort
    [ @run.as_chat_activity_json, Api::App::V1::Presenter.activity(@run),
      attempt.snapshot, attempt.agent_runtime_events.pluck(:data) ].each do |projection|
      %w[private-parent private-child PRIVATE_ROLE PRIVATE_PROMPT PRIVATE_RESULT PRIVATE_ERROR].each do |canary|
        assert_not_includes projection.to_json, canary
      end
    end
    @run.as_chat_activity_json.to_json.tap do |json|
      attempt.snapshot.fetch(RuntimeSubagents::KEY).fetch("identities").each { |hash| assert_not_includes json, hash }
    end
    assert_not_includes Api::App::V1::Presenter.activity(@run).to_json, "Helper"
  end

  test "hidden narration omits helper details at ingress and hides already shared history on immediate revoke" do
    start_helpers
    ingest(2, "agent.status_changed", helper)
    assert_includes @run.as_chat_activity_json.to_json, "Helper"
    # Do not reload the run: its cached agent association must not leak.
    @agent.update!(share_working_narration: false)
    json = @run.as_chat_activity_json
    assert_empty json[:snapshot]["subagents"]
    assert_equal 0, json[:snapshot]["subagents_overflow"]
    assert_not json[:snapshot]["subagents_overflow_capped"]
    assert_not_includes json.to_json, "Helper"
    assert_not_includes json.to_json, "synthetic-helper-model"
    assert_not json[:events].any? { |event| event[:type] == "agent.status_changed" }
    ingest(3, "agent.status_changed", helper.merge("agent_nickname" => "HIDDEN_NEW_HELPER"))
    ingest(4, "heartbeat", { "subagents" => [ helper ] })
    attempt = @run.agent_runtime_attempts.first
    assert_not attempt.snapshot.key?(RuntimeSubagents::KEY)
    assert_not_includes attempt.agent_runtime_events.pluck(:data).to_json, "HIDDEN_NEW_HELPER"
    assert_empty helper_snapshot["subagents"]
  end

  test "optout scrubbed heartbeat replay does not conflict with accepted mixed batch digests" do
    start_helpers
    events = [
      { "seq" => 2, "type" => "agent.status_changed", "data" => helper },
      { "seq" => 3, "type" => "heartbeat", "data" => { "operations" => [], "subagents" => [ helper ] } },
      { "seq" => 4, "type" => "turn.started", "data" => {} }
    ]
    payload = { "schema_version" => 1, "run_id" => @run.run_id, "attempt_id" => @attempt_id,
      "attempt_number" => 1, "events" => events }
    RuntimeActivityIngestion.new(@run, payload).call
    @agent.update!(share_working_narration: false)
    replay = payload.deep_dup
    replay["events"].reject! { |event| event["type"] == "agent.status_changed" }
    replay["events"].find { |event| event["type"] == "heartbeat" }["data"].delete("subagents")
    assert_no_difference "AgentRuntimeEvent.count" do
      RuntimeActivityIngestion.new(@run, replay).call
    end
    assert_equal "running", @run.reload.execution_state
    assert_empty helper_snapshot["subagents"]
  end

  test "invalid helper heartbeat rolls back a mixed batch without partial lifecycle state" do
    start_helpers
    payload = { "schema_version" => 1, "run_id" => @run.run_id, "attempt_id" => @attempt_id,
      "attempt_number" => 1, "events" => [
        { "seq" => 2, "type" => "agent.status_changed", "data" => helper },
        { "seq" => 3, "type" => "heartbeat", "data" => { "subagents" => [ helper.merge("status" => "invalid") ] } }
      ] }
    assert_no_difference "AgentRuntimeEvent.count" do
      assert_raises(RuntimeActivityIngestion::Invalid) { RuntimeActivityIngestion.new(@run, payload).call }
    end
    assert_empty helper_snapshot["subagents"]
    ingest(2, "agent.status_changed", helper)
    assert_equal "running", helper_snapshot["subagents"].first["status"]
  end

  test "run consent is also required and malformed ingress is bounded" do
    start_helpers
    [
      helper.merge("child_process_id" => "x" * 201), helper.merge("parent_process_id" => nil),
      helper.merge("agent_nickname" => "x" * 201), helper.merge("model" => []),
      helper.merge("status" => { "completed" => "private" }), helper.merge("status" => "unknown")
    ].each do |invalid|
      assert_raises(RuntimeActivityIngestion::Invalid) { ingest(2, "agent.status_changed", invalid) }
    end
    assert_raises(RuntimeActivityIngestion::Invalid) { ingest(2, "heartbeat", { "subagents" => [ helper ] * 33 }) }
    @run.update!(narration_shared: false)
    ingest(2, "agent.status_changed", helper)
    assert_empty helper_snapshot["subagents"]
    assert_not_includes @run.agent_runtime_attempts.first.snapshot.to_json, "Helper"
  end

  test "old raw helper event and unknown snapshot fields are not presented" do
    start_helpers
    ingest(2, "agent.status_changed", helper)
    attempt = @run.agent_runtime_attempts.first
    attempt.agent_runtime_events.last.update!(data: helper.merge("result" => "PRIVATE_RESULT"))
    attempt.update!(snapshot: attempt.snapshot.merge("subagents" => [ helper ], "child_process_id" => "PRIVATE_ID"))
    public_json = @run.as_chat_activity_json.to_json
    %w[private-child private-parent PRIVATE_RESULT PRIVATE_ID _subagents identities].each do |canary|
      assert_not_includes public_json, canary
    end
  end

  test "old runs default empty and no tool name can invent a helper" do
    start_helpers
    ingest(2, "tool.started", { "operation_id" => "spawn_agent", "category" => "delegation" })
    assert_empty helper_snapshot["subagents"]
    assert_equal 0, helper_snapshot["subagents_overflow"]
  end

  test "synchronous terminal and detail budget cannot leave active helper presentation" do
    start_helpers
    ingest(2, "agent.status_changed", helper)
    @run.agent_runtime_attempts.first.update!(detail_count: 2_000)
    assert_no_difference "AgentRuntimeEvent.count" do
      ingest(3, "agent.status_changed", helper.merge("status" => "completed"))
    end
    assert_equal "completed", helper_snapshot["subagents"].first["status"]
    ingest(4, "agent.status_changed", helper)
    @run.record_result!(status: 200, body: { "status" => "ok" })
    assert_equal "unknown", helper_snapshot["subagents"].first["status"]
  end

  private

  def start_helpers
    @agent.update!(share_working_narration: true)
    @run.update!(narration_shared: true)
    ingest(1, "attempt.started", { "narration_capability" => "unknown" })
  end

  def helper
    { "parent_process_id" => "private-parent", "child_process_id" => "private-child",
      "agent_nickname" => "Helper", "model" => "synthetic-helper-model", "status" => "running" }
  end

  def helper_snapshot
    @run.reload.as_chat_activity_json[:snapshot]
  end

  def ingest(seq, type, data = {}, attempt_id: @attempt_id, number: 1)
    RuntimeActivityIngestion.new(@run, {
      "schema_version" => 1, "run_id" => @run.run_id,
      "attempt_id" => attempt_id, "attempt_number" => number,
      "events" => [ { "seq" => seq, "type" => type, "data" => data } ]
    }).call
  end

end
