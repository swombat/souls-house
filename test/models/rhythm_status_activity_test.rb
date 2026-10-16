require "test_helper"
require "action_cable/test_helper"

class RhythmStatusActivityTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  self.use_transactional_tests = false

  setup do
    @user = users(:user_1)
    @account = Account.create!(name: "Rhythm status #{SecureRandom.hex(4)}", account_type: "team")
    @account.memberships.create!(user: @user, role: "owner", confirmed_at: Time.current)
    @agent = @account.agents.create!(name: "Synthetic status resident", runtime: "external", model_id: "openrouter/auto")
    @rhythm = Rhythm.create!(account: @account, creator: @user, agents: [ @agent ], title: "Synthetic rhythm",
      opening: "Synthetic opening", cadence: "daily", time_of_day: "09:00", timezone: "UTC")
    @chat, @message = build_source
    @occurrence = create_occurrence(@chat, @message)
    @dispatch = MessageDispatch.accept!(message: @message, target_agent_ids: [ @agent.id ], kind: "rhythm")
  end

  teardown do
    @rhythm.destroy! if @rhythm && Rhythm.exists?(@rhythm.id)
    @account.destroy!
  end

  test "dispatch creation status reason and deletion refresh the displayed occurrence status" do
    @dispatch.destroy!
    assert_includes presented_status, "no activation recorded"

    assert_refresh_after_commit do
      @dispatch = MessageDispatch.accept!(message: @message, target_agent_ids: [ @agent.id ], kind: "rhythm")
    end
    assert_equal "pending", presented_status
    assert_refresh_after_commit { @dispatch.update!(status: "reserved") }
    assert_equal "reserved", presented_status
    assert_refresh_after_commit { @dispatch.update!(reason: "Synthetic explanation") }
    assert_equal "reserved · Synthetic explanation", presented_status
    assert_refresh_after_commit { @dispatch.destroy! }
    assert_includes presented_status, "no activation recorded"
  end

  test "a dispatch created before its occurrence resolves the account after commit without a stale nil association" do
    chat, message = build_source
    messages = capture_broadcasts(stream) do
      MessageDispatch.transaction do
        dispatch = MessageDispatch.accept!(message: message, target_agent_ids: [ @agent.id ], kind: "rhythm")
        assert_nil dispatch.message.rhythm_occurrence
        create_occurrence(chat, message)
        assert_no_broadcasts(stream) { dispatch.update!(settled_at: Time.current) }
      end
    end
    # One core occurrence marker and one dispatch marker, despite the later
    # metadata save and the previously cached missing occurrence.
    assert_equal [ { "action" => "refresh" } ] * 2, messages
  end

  test "expiry refreshes without starting or reserving work" do
    travel_to @dispatch.expires_at + 1.second do
      assert_no_enqueued_jobs do
        assert_no_difference "AgentRuntimeInteraction.count" do
          assert_refresh_after_commit { @dispatch.settle_lapsed! }
        end
      end
    end
    assert_equal "expired · not_started_in_time", presented_status
  end

  test "opening discard cancellation refreshes without new work" do
    assert_no_enqueued_jobs do
      assert_refresh_after_commit { @message.discard_as_author! }
    end
    assert_equal "cancelled · discarded", presented_status
  end

  test "reservation and claim refresh the linked run status without calling a runtime" do
    ManualAgentResponseJob.stub(:perform_later, nil) do
      assert_refresh_after_commit { @dispatch.reserve! }
    end
    run = @dispatch.reload.runtime_interactions.sole
    assert_includes presented_status, "#{@agent.name}: queued"
    assert_refresh_after_commit { assert run.claim_dispatch! }
    assert_includes presented_status, "#{@agent.name}: preparing"
  end

  test "dispatch recovery expiry targets and singular run pointer are not displayed status changes" do
    run = build_run
    run.save!
    assert_no_broadcasts(stream) do
      @dispatch.update!(settled_at: Time.current)
      @dispatch.update!(expires_at: 1.hour.from_now)
      @dispatch.update!(accepted_at: 1.minute.ago)
      @dispatch.update!(target_agent_ids: [])
      @dispatch.update!(runtime_interaction: run)
      @dispatch.touch
    end
    assert_includes presented_status, "#{@agent.name}: queued"
  end

  test "runtime creation removal and resident reassignment refresh the rendered run list" do
    run = build_run
    assert_refresh_after_commit { run.save! }
    assert_includes presented_status, "#{@agent.name}: queued"
    replacement = @account.agents.create!(name: "Synthetic replacement", runtime: "external", model_id: "openrouter/auto")
    assert_refresh_after_commit { run.update!(agent: replacement) }
    assert_includes presented_status, "Former resident: queued"
    assert_refresh_after_commit { run.destroy! }
    assert_equal "pending", presented_status
  end

  %w[running completed failed timed_out cancelled busy outcome_unknown].each do |state|
    test "runtime #{state} transition refreshes its occurrence" do
      run = build_run
      run.save!
      assert_refresh_after_commit do
        if state == "running"
          run.update!(execution_state: state)
        else
          run.finish_execution!(state)
        end
      end
      assert_includes presented_status, "#{@agent.name}: #{state}"
    end
  end

  test "an unclaimed runtime deadline refreshes cancellation without retrying work" do
    run = build_run
    run.execution_deadline_at = 1.second.ago
    run.save!
    assert_no_enqueued_jobs(only: [ ManualAgentResponseJob, AllAgentsResponseJob ]) do
      assert_refresh_after_commit { run.reconcile_activity! }
    end
    assert_includes presented_status, "#{@agent.name}: cancelled"
  end

  test "runtime result completion refreshes only the displayed execution transition" do
    run = build_run
    run.save!
    assert_refresh_after_commit do
      run.record_result!(status: 200, body: { "status" => "ok", "returncode" => 0,
        "telemetry" => { "schema_version" => 1, "usage" => { "scope" => "invocation", "output_tokens" => 12 } } })
    end
    assert_includes presented_status, "#{@agent.name}: completed"
    assert_equal 12, run.output_tokens
  end

  test "telemetry transport leases finish timestamp and run identity alone do not refresh rhythms" do
    run = build_run
    run.save!
    assert_no_broadcasts(stream) do
      run.update!(input_tokens: 10, output_tokens: 5, reasoning_output_tokens: 2, provider_request_count: 1)
      run.update!(telemetry_schema_version: 1, usage_scope: "invocation", usage_complete: true,
        response_body: { "telemetry" => { "usage" => { "output_tokens" => 5 } } })
      run.update!(runtime_status: "ok", transport_status: 200, runtime_returncode: 0,
        stdout: "Synthetic output", stderr: "", duration_ms: 20)
      run.update!(execution_deadline_at: 1.hour.from_now, dispatch_claimed_at: Time.current,
        activity_token_expires_at: 2.hours.from_now, narration_shared: true)
      run.update!(run_id: SecureRandom.uuid, finished_at: Time.current)
      run.touch
      attempt = run.agent_runtime_attempts.create!(attempt_id: SecureRandom.uuid, number: 1,
        last_report_at: Time.current, snapshot: { "operations" => [] })
      attempt.agent_runtime_events.create!(seq: 1, event_type: "usage.updated", payload_digest: "synthetic",
        data: { "output_tokens" => 6 })
      attempt.update!(last_report_at: Time.current, revision: 1)
    end
    assert_includes presented_status, "#{@agent.name}: queued"
  end

  test "a later metadata or telemetry save cannot hide an earlier state change in the outer transaction" do
    run = build_run
    run.save!
    assert_refresh_after_commit do
      @dispatch.update!(reason: "Synthetic reason")
      @dispatch.update!(settled_at: Time.current)
      run.update!(execution_state: "running")
      run.update!(output_tokens: 1)
    end
    assert_includes presented_status, "Synthetic reason"
    assert_includes presented_status, "#{@agent.name}: running"
  end

  test "attaching and detaching a runtime refreshes the affected rhythm even with a cached old dispatch" do
    run = build_run
    run.save!
    assert_equal @dispatch, run.message_dispatch
    ordinary = ordinary_dispatch("mention")
    assert_refresh_after_commit { run.update!(message_dispatch: ordinary) }
    assert_equal "pending", presented_status
    assert_no_broadcasts(stream) { run.update!(execution_state: "running") }
    assert_refresh_after_commit { run.update!(message_dispatch: @dispatch) }
    assert_includes presented_status, "#{@agent.name}: running"
    assert_refresh_after_commit { run.update!(message_dispatch: nil) }
    assert_equal "pending", presented_status
  end

  %i[dispatch runtime].each do |kind|
    test "#{kind} create update and destroy rollback emit no rhythm marker" do
      record = kind == :dispatch ? @dispatch : build_run.tap(&:save!)
      assert_rollback_without_refresh do
        kind == :dispatch ? record.update!(status: "expired", reason: "Synthetic expiry") : record.update!(execution_state: "running")
      end
      assert_equal(kind == :dispatch ? "pending" : "queued", record.reload.public_send(kind == :dispatch ? :status : :execution_state))
      assert_rollback_without_refresh { record.destroy! }
      assert record.class.exists?(record.id)
      record.destroy!
      fresh = kind == :dispatch ? @dispatch.dup : build_run
      assert_rollback_without_refresh { fresh.save! }
      assert_not fresh.persisted?
    end

    test "#{kind} savepoint rollback emits nothing when the outer transaction commits" do
      record = kind == :dispatch ? @dispatch : build_run.tap(&:save!)
      assert_no_broadcasts(stream) do
        MessageDispatch.transaction do
          MessageDispatch.transaction(requires_new: true) do
            kind == :dispatch ? record.update!(reason: "Rolled back") : record.update!(execution_state: "running")
            raise ActiveRecord::Rollback
          end
        end
      end
    end
  end

  %w[mention automatic invoke].each do |kind|
    test "#{kind} dispatch and runtime lifecycle in a rhythm chat never refresh rhythms" do
      # The first human reply legitimately promotes a quiet run. Establish
      # that listing change before measuring unrelated dispatch activity.
      @chat.messages.create!(role: "user", user: @user, content: "Already listed", suppress_automatic_dispatch: true)
      assert_no_broadcasts(stream) do
        dispatch = ordinary_dispatch(kind)
        dispatch.update!(status: "reserved", reason: "Synthetic unrelated status")
        run = build_run(dispatch: dispatch)
        run.save!
        run.update!(execution_state: "running")
        run.finish_execution!("completed")
        run.destroy!
        dispatch.destroy!
      end
    end
  end

  test "a rhythm-kind dispatch with no occurrence or no live rhythm emits nothing" do
    assert_no_broadcasts(stream) do
      _, message = build_source
      dispatch = MessageDispatch.accept!(message: message, target_agent_ids: [ @agent.id ], kind: "rhythm")
      dispatch.update!(reason: "Not an occurrence")
      run = build_run(dispatch: dispatch)
      run.save!
      run.finish_execution!("completed")
    end
    run = build_run
    run.save!
    @rhythm.destroy!
    assert_no_broadcasts(stream) do
      @dispatch.update!(status: "expired", reason: "Retained snapshot")
      run.update!(execution_state: "running")
      run.destroy!
      @dispatch.destroy!
    end
  end

  test "an unlinked runtime in a rhythm chat emits no marker" do
    assert_no_broadcasts(stream) do
      run = build_run(dispatch: nil)
      run.save!
      run.update!(execution_state: "running")
      run.finish_execution!("completed")
      run.destroy!
    end
  end

  test "a guest runtime refreshes the occurrence account and never the residents home account" do
    guest = agents(:other_account_agent)
    GuestMembership.create!(account: @account, agent: guest, added_by: @user)
    @chat.chat_agents.create!(agent: guest)
    run = build_run
    run.agent = guest
    assert_no_broadcasts(stream(guest.account)) do
      assert_refresh_after_commit { run.save! }
      assert_refresh_after_commit { run.update!(execution_state: "running") }
      assert_refresh_after_commit { run.destroy! }
    end
  end

  test "ordinary messages and touches in the occurrence chat never refresh rhythms" do
    assert_no_broadcasts(stream) do
      @chat.messages.create!(role: "assistant", agent: @agent, content: "Synthetic reply", suppress_automatic_dispatch: true)
      @chat.touch
    end
  end

  private

  def stream(account = @account)
    "RhythmActivity:#{account.obfuscated_id}"
  end

  def assert_refresh_after_commit
    messages = capture_broadcasts(stream) do
      assert_no_broadcasts(stream(accounts(:existing_user_account))) do
        MessageDispatch.transaction do
          assert_no_broadcasts(stream) { yield }
        end
      end
    end
    assert_not_empty messages
    assert messages.all? { |message| message == { "action" => "refresh" } }
  end

  def assert_rollback_without_refresh
    assert_no_broadcasts(stream) do
      MessageDispatch.transaction(requires_new: true) do
        yield
        raise ActiveRecord::Rollback
      end
    end
  end

  def presented_status
    rhythm = Rhythm.find(@rhythm.id)
    RhythmPresentation.new(rhythm, user: @user).as_json(history: true)[:occurrences]
      .find { |occurrence| occurrence[:id] == @occurrence.id.to_s }.fetch(:status)
  end

  def build_source
    chat = @account.chats.create!(title: "Synthetic status run", manual_responses: true, agents: [ @agent ])
    message = chat.messages.create!(role: "user", user: @user, content: "Synthetic opening", suppress_automatic_dispatch: true)
    [ chat, message ]
  end

  def create_occurrence(chat, message)
    @rhythm.occurrences.create!(chat: chat, message: message, creator: @user, creator_label: "Synthetic human",
      title: "Synthetic run", rhythm_title: @rhythm.title, opening: "Synthetic opening", scheduled_for: Time.current)
  end

  def build_run(dispatch: @dispatch)
    AgentRuntimeInteraction.new(agent: @agent, chat: @chat, message_dispatch: dispatch,
      trigger_kind: "conversation", started_at: Time.current, execution_state: "queued", run_id: SecureRandom.uuid)
  end

  def ordinary_dispatch(kind)
    now = Time.current
    if kind == "invoke"
      MessageDispatch.create!(kind: kind, chat: @chat, user: @user, target_agent_ids: [ @agent.id ],
        client_invocation_id: SecureRandom.uuid, request_digest: "v1:synthetic", accepted_at: now, expires_at: now + 10.minutes)
    else
      message = @chat.messages.create!(role: "user", user: @user, content: "Synthetic request", suppress_automatic_dispatch: true)
      MessageDispatch.accept!(message: message, target_agent_ids: [ @agent.id ], kind: kind)
    end
  end

end
