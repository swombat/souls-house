require "test_helper"

class AccountCostActivityTest < ActiveSupport::TestCase

  include ActionCable::TestHelper
  self.use_transactional_tests = false

  setup do
    @home = Account.create!(name: "Cost #{SecureRandom.hex(4)}", account_type: :team)
    @other = Account.create!(name: "Cost guest #{SecureRandom.hex(4)}", account_type: :team)
    @agent = @home.agents.create!(name: "Cost resident", runtime: "external")
    @run = @agent.agent_runtime_interactions.create!(trigger_kind: "wake", started_at: Time.current)
    clear_enqueued_jobs
  end

  teardown do
    [ @home, @other ].each { |account| account.reload.destroy! }
  end

  test "actual result commits cost bearing usage and completion in one home only marker" do
    [ @home, @other ].each { |account| account.add_user!(users(:user_1), role: "owner", skip_confirmation: true) }
    GuestMembership.create!(agent: @agent, account: @other, added_by: users(:user_1))
    assert_no_broadcasts(stream(@other)) do
      marker do
        @run.record_result!(status: 200, body: result_body)
      end
    end
    assert_equal 100, @run.reload.uncached_input_tokens
    assert_equal "estimated", @run.estimated_cost[:status]
    assert @run.finished_at?
  end

  test "record trigger terminal writer emits once but its initial reservation stays quiet" do
    result = { status: 200, body: result_body }
    recorded = nil
    marker do
      assert_equal result, AgentRuntimeInteraction.record_trigger!(
        agent: @agent, chat: nil, trigger_kind: "wake", conversation_id: nil,
        requested_by: "producer test", session_id: SecureRandom.uuid,
        endpoint_url: "https://runtime.example.test", request_text: "Synthetic wake"
      ) { |run|
        recorded = run
        assert_no_broadcasts(stream) { run.reload }
        result
      }
    end
    assert recorded.reload.finished_at?
    assert_equal 100, recorded.uncached_input_tokens
  end

  test "external response request finishes its reserved interaction with one cost hint" do
    @home.update!(anthropic_api_key: "synthetic-test-key")
    @agent.update!(model_id: "anthropic/claude-opus-4.6", uuid: SecureRandom.uuid,
      endpoint_url: "https://runtime.example.test", trigger_bearer_token: "synthetic",
      health_state: "healthy")
    chat = @home.chats.create!(title: "Actual response request", manual_responses: true, agents: [ @agent ])
    sandbox = Object.new
    sandbox.define_singleton_method(:with_runtime) { |&block| block.call }
    client = Object.new
    body = result_body
    client.define_singleton_method(:request_response) { |**| { status: 200, body: body } }
    Agents::Sandbox.stub(:new, sandbox) do
      ChaosTriggerClient.stub(:new, client) do
        Mnemodyne::Provision.stub(:call, nil) do
          marker do
            result = ExternalAgentResponseRequest.new(agent: @agent, chat: chat).call
            assert_equal 200, result[:status]
          end
        end
      end
    end
    run = chat.agent_runtime_interactions.last
    assert run.finished_at?
    assert_equal 100, run.uncached_input_tokens
  end

  test "each usage field and late schema correction notify without a finished_at change" do
    @run.record_result!(status: 200, body: result_body)
    finished = @run.finished_at
    (AgentRuntimeInteraction::COST_ACTIVITY_FIELDS - %w[finished_at]).each do |field|
      value = case field
      when "usage_scope" then "trigger"
      when "usage_complete" then false
      else @run[field].to_i + 1
      end
      marker { @run.update!(field => value) }
      assert_equal finished, @run.reload.finished_at
      assert_no_broadcasts(stream) { @run.update!(field => value) }
    end
  end

  test "health activity messages acceptance and callback bypass bookkeeping are quiet" do
    assert_no_broadcasts(stream) do
      @agent.update!(health_state: "healthy", last_health_check_at: Time.current)
      @run.record_result!(status: 202, body: { "status" => "queued" })
      @run.update!(stdout: "private output", runtime_status: "running", response_body: { "private" => true })
      @run.update_columns(follow_through_checked_at: Time.current)
      AgentRuntimeInteraction.where(id: @run.id).update_all(follow_through_checked_at: Time.current)
      @run.touch
      chat = @home.chats.create!(title: "Quiet", manual_responses: true, agents: [ @agent ])
      chat.messages.create!(role: "user", content: "Private ordinary message")
    end
  end

  test "multiple runs and writes coalesce per account transaction and wait for commit" do
    other_run = @agent.agent_runtime_interactions.create!(trigger_kind: "wake", started_at: Time.current)
    marker do
      AgentRuntimeInteraction.transaction do
        assert_no_broadcasts(stream) do
          @run.update!(input_tokens: 2)
          @run.update!(output_tokens: 3)
          other_run.record_result!(status: 200, body: result_body)
          @run.touch
        end
      end
    end
    marker { @run.update!(output_tokens: 4) }
  end

  test "coalescing retains each distinct home once without leaking account identifiers" do
    visitor = @other.agents.create!(name: "Other cost resident", runtime: "offline")
    other_run = visitor.agent_runtime_interactions.create!(trigger_kind: "wake", started_at: Time.current)
    marker do
      marker(@other) do
        AgentRuntimeInteraction.transaction do
          @run.update!(input_tokens: 1)
          other_run.update!(input_tokens: 2)
          @run.update!(output_tokens: 3)
          other_run.update!(output_tokens: 4)
        end
      end
    end
  end

  test "rollback clears pending coalescing state including rolled back savepoint" do
    assert_no_broadcasts(stream) do
      AgentRuntimeInteraction.transaction do
        @run.update!(input_tokens: 12)
        raise ActiveRecord::Rollback
      end
      @run.reload
      AgentRuntimeInteraction.transaction do
        AgentRuntimeInteraction.transaction(requires_new: true) do
          @run.update!(output_tokens: 14)
          raise ActiveRecord::Rollback
        end
      end
    end
    @run.reload
    marker do
      AgentRuntimeInteraction.transaction do
        @run.update!(input_tokens: 13)
        AgentRuntimeInteraction.transaction(requires_new: true) do
          @run.update!(output_tokens: 14)
          raise ActiveRecord::Rollback
        end
      end
    end
  end

  test "committed savepoint waits for outer commit and outer rollback drops it" do
    marker do
      AgentRuntimeInteraction.transaction do
        AgentRuntimeInteraction.transaction(requires_new: true) { @run.update!(input_tokens: 10) }
        assert_no_broadcasts(stream) { @run.reload }
      end
    end
    assert_no_broadcasts(stream) do
      AgentRuntimeInteraction.transaction do
        AgentRuntimeInteraction.transaction(requires_new: true) { @run.update!(input_tokens: 11) }
        raise ActiveRecord::Rollback
      end
    end
  end

  test "cost ownership uses persisted home even with stale loaded agent" do
    @run.agent
    @agent.update!(account: @other)
    assert_no_broadcasts(stream) { marker(@other) { @run.update!(input_tokens: 17) } }
  end

  test "errors finish but pending turn acknowledgement errors stay quiet" do
    marker { @run.record_error!(RuntimeError.new("synthetic")) }
    run = @agent.agent_runtime_interactions.create!(trigger_kind: "wake", started_at: Time.current)
    ResidentTurn.enqueue!(run, { session_id: SecureRandom.uuid })
    assert_no_broadcasts(stream) { run.record_error!(RuntimeError.new("ack failed")) }
    assert_nil run.reload.finished_at
  end

  test "ResidentTurn finish and repeated finish preserve accounting and stay narrow" do
    turn = ResidentTurn.enqueue!(@run, { session_id: SecureRandom.uuid })
    marker { turn.finish!({ "status" => 200, "body" => result_body }) }
    assert_equal 100, @run.reload.uncached_input_tokens
    assert_no_broadcasts(stream) { turn.finish!({ "status" => 200, "body" => result_body }) }
  end

  test "containment synthetic cancellation retains already received usage without marker" do
    turn = ResidentTurn.enqueue!(@run, { session_id: SecureRandom.uuid })
    marker { @run.record_result!(status: 200, body: result_body) }
    assert_no_broadcasts(stream) do
      turn.finish!({ "status" => 409, "body" => { "status" => "cancelled" } }, cancelled: true)
    end
    assert_equal 100, @run.reload.uncached_input_tokens
  end

  test "actual containment resolution with no prior result emits terminal hint" do
    @run.update!(endpoint_url: "https://runtime.example.test")
    turn = ResidentTurn.enqueue!(@run, { session_id: SecureRandom.uuid })
    turn.update!(state: "unknown", ledger_id: "previous-ledger")
    client = Object.new
    client.define_singleton_method(:turn_status) { |*| { status: 404, body: { "ledger_id" => "replacement-ledger" } } }
    ChaosTriggerClient.stub(:new, client) do
      marker { turn.resolve_after_containment!(operator: users(:site_admin_user), reason: "Verified synthetic runtime containment") }
    end
    assert @run.reload.finished_at?
    assert_equal "cancelled", turn.reload.state
  end

  test "live ingestion terminal and late usage notify while heartbeat and replay stay quiet" do
    [ @home, @other ].each { |account| account.add_user!(users(:user_1), role: "owner", skip_confirmation: true) }
    GuestMembership.create!(agent: @agent, account: @other, added_by: users(:user_1))
    chat = @other.chats.create!(title: "Live guest cost", manual_responses: true, agents: [ @agent ])
    run = AgentRuntimeInteraction.reserve!(agent: @agent, chat: chat)
    run.claim_dispatch!
    run.activity_configuration!
    attempt = SecureRandom.uuid
    ingest = ->(seq, type, data = {}) do
      RuntimeActivityIngestion.new(run, {
        "schema_version" => 1, "run_id" => run.run_id,
        "attempt_id" => attempt, "attempt_number" => 1,
        "events" => [ { "seq" => seq, "type" => type, "data" => data } ]
      }).call
    end
    assert_no_broadcasts(stream) do
      ingest.call(1, "attempt.started", { "narration_capability" => "unknown" })
      ingest.call(2, "heartbeat")
    end
    terminal = { "outcome" => "completed", "runtime_status" => "ok", "telemetry" => result_body["telemetry"] }
    assert_no_broadcasts(stream(@other)) { marker { ingest.call(3, "supervisor.finished", terminal) } }
    assert_equal 100, run.reload.uncached_input_tokens
    assert_no_broadcasts(stream) { ingest.call(3, "supervisor.finished", terminal) }
    marker { run.update!(output_tokens: 42) }
    assert_no_broadcasts(stream) { ingest.call(4, "heartbeat") }
  end

  test "failed terminal ingestion rolls back accounting and emits nothing" do
    chat = @home.chats.create!(title: "Invalid terminal batch", manual_responses: true, agents: [ @agent ])
    run = AgentRuntimeInteraction.reserve!(agent: @agent, chat: chat)
    run.claim_dispatch!
    attempt = SecureRandom.uuid
    payload = {
      "schema_version" => 1, "run_id" => run.run_id,
      "attempt_id" => attempt, "attempt_number" => 1,
      "events" => [
        { "seq" => 1, "type" => "attempt.started", "data" => { "narration_capability" => "unknown" } },
        { "seq" => 2, "type" => "supervisor.finished",
          "data" => { "outcome" => "completed", "runtime_status" => "ok", "telemetry" => result_body["telemetry"] } },
        { "seq" => 3, "type" => "tool.started", "data" => { "category" => "invalid" } }
      ]
    }
    assert_no_broadcasts(stream) do
      assert_raises(RuntimeActivityIngestion::Invalid) { RuntimeActivityIngestion.new(run, payload).call }
    end
    assert_nil run.reload.finished_at
    assert_nil run.uncached_input_tokens
    assert_empty run.agent_runtime_attempts
  end

  test "actual follow through bookkeeping and unique conflict fallback emit no cost hints" do
    chat = @home.chats.create!(title: "Bookkeeping", manual_responses: true, agents: [ @agent ])
    @run.update!(chat: chat, trigger_kind: "conversation")
    @run.record_result!(status: 200, body: result_body)
    FollowThroughCheck.stub(:enabled_for?, true) do
      assert_no_broadcasts(stream) { FollowThroughCheckJob.perform_now(@run.id) }
      assert @run.reload.follow_through_checked_at?

      @run.update_columns(follow_through_checked_at: nil)
      check = Object.new
      reads = 0
      check.define_singleton_method(:evidence_boundary) do
        reads += 1
        raise ActiveRecord::RecordNotUnique, "synthetic concurrent nudge" if reads == 2
        []
      end
      check.define_singleton_method(:call) { :clear }
      FollowThroughCheck.stub(:new, ->(*) { check }) do
        assert_no_broadcasts(stream) { FollowThroughCheckJob.perform_now(@run.id) }
      end
      assert @run.reload.follow_through_checked_at?
      assert_equal 2, reads
    end
  end

  test "actual failure notice bypass and its system message do not emit cost hints" do
    chat = @home.chats.create!(title: "Failure bookkeeping", manual_responses: true, agents: [ @agent ])
    @run.update!(chat: chat, trigger_kind: "conversation", started_at: 10.minutes.ago)
    @run.record_error!(RuntimeError.new("synthetic failure"))
    run = @agent.agent_runtime_interactions.create!(chat: chat, trigger_kind: "conversation", started_at: 5.minutes.ago)
    run.record_error!(RuntimeError.new("synthetic repeated failure"))
    assert_no_broadcasts(stream) do
      assert_difference(-> { chat.messages.where(role: "system").count }, 1) do
        RunFailureNoticeJob.perform_now(run.id)
        RunFailureNoticeJob.perform_now(run.id)
      end
    end
    assert run.reload.failure_notice_message_id
  end

  test "live execution termination emits without a result and repeated terminal finish is quiet" do
    chat = @home.chats.create!(title: "Terminated", manual_responses: true, agents: [ @agent ])
    run = AgentRuntimeInteraction.reserve!(agent: @agent, chat: chat)
    marker { run.finish_execution!("failed") }
    assert_no_broadcasts(stream) { run.finish_execution!("failed") }
  end

  test "already accounted transport rejects duplicate terminal callback without a new marker" do
    @run.record_result!(status: 200, body: result_body)
    assert_no_broadcasts(stream) do
      @run.record_result!({ status: nil, body: result_body }, from_callback: true)
    end
    assert_equal 100, @run.reload.uncached_input_tokens
  end

  test "expired undispatched reconciliation notifies actual terminal write" do
    chat = @home.chats.create!(title: "Expired", manual_responses: true, agents: [ @agent ])
    run = AgentRuntimeInteraction.reserve!(agent: @agent, chat: chat)
    run.update!(execution_deadline_at: 1.second.ago)
    marker { run.reconcile_activity! }
    assert_equal "cancelled", run.reload.execution_state
    assert_no_broadcasts(stream) { run.reconcile_activity! }
  end

  private

  def result_body
    { "status" => "ok", "telemetry" => {
      "schema_version" => 1,
      "runtime" => { "provider" => "anthropic", "model" => "anthropic/claude-opus-4.6" },
      "usage" => { "scope" => "invocation", "complete" => true, "input_tokens" => 100,
        "uncached_input_tokens" => 100, "cache_creation_input_tokens" => 0,
        "cache_read_input_tokens" => 0, "output_tokens" => 20 }
    } }
  end

  def stream(account = @home)
    "AccountCostActivity:#{account.to_param}"
  end

  def marker(account = @home)
    assert_equal [ { "action" => "refresh" } ], capture_broadcasts(stream(account)) { yield }
  end

end
