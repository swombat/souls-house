require "test_helper"

# The notice is driven by the run finishing (FailureReport's callback and the
# job), so these finish runs: the thing under test is "every wake fails and
# nobody is told", not a method.
class ScheduledRunFailureNoticeTest < ActiveJob::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(runtime: "external", uuid: SecureRandom.uuid_v7, endpoint_url: "https://agent.example.com", trigger_bearer_token: "tr_valid")
    @room = @agent.account.chats.create!(title: "Room", manual_responses: true, agents: [ @agent ])
    owner = @agent.account.owner
    (owner.profile || owner.build_profile).update!(timezone: "Madrid")
  end

  test "a finished scheduled run queues the check for failures and completions, not for busy or lost ends" do
    %w[failed timed_out completed].each do |state|
      assert_enqueued_with(job: ScheduledRunFailureNoticeJob) { running_run("wake").finish_execution!(state) }
    end
    %w[busy outcome_unknown cancelled].each do |state|
      assert_no_enqueued_jobs(only: ScheduledRunFailureNoticeJob) { running_run("wake").finish_execution!(state) }
    end
    assert_no_enqueued_jobs(only: RunFailureNoticeJob) { running_run("memory_aggregation_daily").finish_execution!("failed") }
    assert_no_enqueued_jobs(only: ScheduledRunFailureNoticeJob) { running_run("conversation", chat: @room).finish_execution!("failed") }
  end

  test "the first failed scheduled run says nothing" do
    run = scheduled_run("wake", "failed", at: 1.hour.ago)
    perform_enqueued_jobs(only: ScheduledRunFailureNoticeJob) { ScheduledRunFailureNoticeJob.perform_now(run.id) }
    assert_empty failing_streaks
    assert_nil notice_chat
  end

  test "the second failed scheduled run opens one conversation in Main that wakes nobody, once per streak" do
    scheduled_run("wake", "failed", at: 2.hours.ago, runtime_status: "error", runtime_returncode: 1, transport_status: 500)
    second = scheduled_run("memory_aggregation_daily", "failed", at: 1.hour.ago, runtime_status: "error", runtime_returncode: 1, transport_status: 500)
    ScheduledRunFailureNoticeJob.perform_now(second.id)
    ScheduledRunFailureNoticeJob.perform_now(second.id)
    third = scheduled_run("wake", "failed", at: 30.minutes.ago, runtime_status: "error", runtime_returncode: 1, transport_status: 500)
    ScheduledRunFailureNoticeJob.perform_now(third.id)

    streak = failing_streaks.sole
    chat = Chat.find(streak.data.fetch("chat_id"))
    assert_nil chat.room
    assert_equal [ @agent ], chat.agents.to_a
    assert_equal @agent.account, chat.account
    assert_empty MessageDispatch.where(chat: chat)
    message = chat.messages.sole
    assert_equal "system", message.role
    assert_nil message.agent_id
    assert_match(/\A\[System Notice\] #{@agent.name}'s scheduled runs are failing: the run ended in an error \(2nd failed scheduled run in a row since \d+ \w+ \d\d:\d\d CES?T\)\./, message.content)
    assert_includes message.content, "ended as a failed run (some work may have happened before it failed)"
    assert_includes message.content, "conversations are separate"
    link = message.notice_link.stringify_keys
    assert_equal "Why?", link["label"]
    assert_equal Rails.application.routes.url_helpers.edit_account_agent_path(@agent.account, @agent, tab: "interactions"), link["path"]
    assert_equal 2, streak.data["count"]
    assert_equal "runtime_error", streak.data["category"]
  end

  test "a completed conversation run does not clear the scheduled streak, and a completed scheduled run closes it once" do
    scheduled_run("wake", "failed", at: 3.hours.ago)
    conversation_run("completed", at: 150.minutes.ago)
    second = scheduled_run("wake", "failed", at: 2.hours.ago)
    ScheduledRunFailureNoticeJob.perform_now(second.id)
    assert_equal 1, failing_streaks.count, "a good chat must not hide a failing wake"

    recovered = scheduled_run("memory_aggregation_daily", "completed", at: 1.hour.ago)
    ScheduledRunFailureNoticeJob.perform_now(recovered.id)
    ScheduledRunFailureNoticeJob.perform_now(recovered.id)

    recovery = recoveries.sole
    assert_equal failing_streaks.sole.id, recovery.data["streak_id"]
    chat = Chat.find(failing_streaks.sole.data.fetch("chat_id"))
    assert_equal 2, chat.messages.count
    assert_match(/\A\[System Notice\] #{@agent.name}'s scheduled runs are completing again as of \d+ \w+ \d\d:\d\d CES?T, after about 2 hours of failures\./, chat.messages.last.content)

    # A new streak after recovery is a new notice, in a new conversation.
    scheduled_run("wake", "failed", at: 40.minutes.ago)
    again = scheduled_run("wake", "failed", at: 20.minutes.ago)
    ScheduledRunFailureNoticeJob.perform_now(again.id)
    assert_equal 2, failing_streaks.count
    assert_not_equal chat.id, failing_streaks.last.data["chat_id"]
  end

  test "a completed conversation run alone closes nothing" do
    scheduled_run("wake", "failed", at: 3.hours.ago)
    second = scheduled_run("wake", "failed", at: 2.hours.ago)
    ScheduledRunFailureNoticeJob.perform_now(second.id)
    chat_run = conversation_run("completed", at: 1.hour.ago)
    ScheduledRunFailureNoticeJob.perform_now(chat_run.id)
    assert_empty recoveries
  end

  test "a house allowance refusal is not claimed: no run carries it, so the line stays general" do
    @agent.update!(model_id: HouseInference::Offering::HAIKU_MODEL_ID)
    scheduled_run("wake", "failed", at: 2.hours.ago, provider: "house", runtime_status: "error", runtime_returncode: 1, transport_status: 500)
    run = scheduled_run("wake", "failed", at: 1.hour.ago, provider: "house", runtime_status: "error", runtime_returncode: 1, transport_status: 500)
    assert_equal "runtime_error", run.failure_category
    ScheduledRunFailureNoticeJob.perform_now(run.id)
    assert_no_match(/allowance/, notice_chat.messages.sole.content)
  end

  test "the shim's auth class is said as an authentication error, not as a missing or expired credential" do
    scheduled_run("wake", "failed", at: 2.hours.ago, provider: "openrouter", runtime_status: "error", runtime_returncode: 1,
      transport_status: 500, response_body: { "status" => "error", "error_kind" => "auth_expired", "stderr" => "sk-or-SECRET no credentials" })
    run = scheduled_run("memory_aggregation_daily", "failed", at: 1.hour.ago, provider: "openrouter", runtime_status: "error",
      runtime_returncode: 1, transport_status: 500, response_body: { "status" => "error", "error_kind" => "auth_expired" })
    assert_equal "authentication_error", run.failure_category
    ScheduledRunFailureNoticeJob.perform_now(run.id)
    content = notice_chat.messages.sole.content
    assert_includes content, "the run's output looked like an authentication error"
    assert_no_match(/missing|expired|SECRET|sk-or/, content)
  end

  test "an old completion arriving after newer failures does not close the newer streak" do
    scheduled_run("wake", "failed", at: 5.hours.ago)
    opener = scheduled_run("wake", "failed", at: 4.hours.ago)
    ScheduledRunFailureNoticeJob.perform_now(opener.id)
    old_success = scheduled_run("wake", "completed", at: 6.hours.ago)
    ScheduledRunFailureNoticeJob.perform_now(old_success.id)
    assert_empty recoveries, "a completion older than the streak ended nothing"
    assert_equal 1, failing_streaks.count
  end

  test "a completion delayed past newer failures closes the old streak and the new one is announced once" do
    scheduled_run("wake", "failed", at: 6.hours.ago)
    opener = scheduled_run("wake", "failed", at: 5.hours.ago)
    ScheduledRunFailureNoticeJob.perform_now(opener.id)
    success = scheduled_run("wake", "completed", at: 4.hours.ago)
    first_new = scheduled_run("wake", "failed", at: 3.hours.ago)
    newer = scheduled_run("wake", "failed", at: 2.hours.ago)
    # The completion's job arrives only now, after both newer failures.
    ScheduledRunFailureNoticeJob.perform_now(success.id)
    ScheduledRunFailureNoticeJob.perform_now(newer.id)
    assert_equal success.id, recoveries.sole.data["run_id"]
    assert_equal 2, failing_streaks.count
    assert_equal first_new.id, failing_streaks.last.data["first_run_id"]
  end

  test "a failed run's job replayed after recovery does not reopen its streak" do
    scheduled_run("wake", "failed", at: 3.hours.ago)
    second = scheduled_run("wake", "failed", at: 2.hours.ago)
    ScheduledRunFailureNoticeJob.perform_now(second.id)
    recovered = scheduled_run("wake", "completed", at: 1.hour.ago)
    ScheduledRunFailureNoticeJob.perform_now(recovered.id)
    ScheduledRunFailureNoticeJob.perform_now(second.id)
    ScheduledRunFailureNoticeJob.perform_now(second.id)
    assert_equal 1, failing_streaks.count
    assert_equal 1, recoveries.count
  end

  test "a completion and a failure finishing at the same instant are ordered by id" do
    at = 1.hour.ago
    scheduled_run("wake", "failed", at: 3.hours.ago)
    opener = scheduled_run("wake", "failed", at: 2.hours.ago)
    ScheduledRunFailureNoticeJob.perform_now(opener.id)
    success = scheduled_run("memory_aggregation_daily", "completed", at: at)
    failure = scheduled_run("wake", "failed", at: at)
    ScheduledRunFailureNoticeJob.perform_now(failure.id)
    ScheduledRunFailureNoticeJob.perform_now(success.id)
    # The failure has the higher id, so it is the newer run: the old streak
    # is closed by the completion, and the new one (one failure) says nothing.
    assert_equal success.id, recoveries.sole.data["run_id"]
    assert_equal 1, failing_streaks.count

    later = scheduled_run("wake", "failed", at: at + 1.minute)
    ScheduledRunFailureNoticeJob.perform_now(later.id)
    assert_equal failure.id, failing_streaks.last.data["first_run_id"]
  end

  test "the first completion ends the streak, so the recovery line names it and not a later one" do
    scheduled_run("wake", "failed", at: 5.hours.ago)
    opener = scheduled_run("wake", "failed", at: 4.hours.ago)
    ScheduledRunFailureNoticeJob.perform_now(opener.id)
    first = scheduled_run("wake", "completed", at: 3.hours.ago)
    second = scheduled_run("memory_aggregation_daily", "completed", at: 1.hour.ago)
    ScheduledRunFailureNoticeJob.perform_now(second.id)
    ScheduledRunFailureNoticeJob.perform_now(first.id)
    assert_equal first.id, recoveries.sole.data["run_id"]
    assert_match(/after about 2 hours of failures/, notice_chat.messages.last.content)
  end

  test "a recovery followed by 201 failures before any job runs still closes the old streak and opens the new one" do
    scheduled_run("wake", "failed", at: 30.hours.ago)
    opener = scheduled_run("wake", "failed", at: 29.hours.ago)
    ScheduledRunFailureNoticeJob.perform_now(opener.id)
    success = scheduled_run("wake", "completed", at: 28.hours.ago)
    bulk_runs("wake", 201, from: 27.hours.ago, transport_status: 500)
    newest = @agent.agent_runtime_interactions.order(:finished_at, :id).last
    ScheduledRunFailureNoticeJob.perform_now(newest.id)
    assert_equal success.id, recoveries.sole.data["run_id"]
    assert_equal 2, failing_streaks.count
    assert_equal 201, failing_streaks.last.data["count"]
  end

  test "conversation rows don't spend the scheduled scan: 2,001 of them can't truncate it or hide a recovery" do
    scheduled_run("wake", "failed", at: 30.hours.ago)
    opener = scheduled_run("wake", "failed", at: 29.hours.ago)
    ScheduledRunFailureNoticeJob.perform_now(opener.id)
    success = scheduled_run("wake", "completed", at: 28.hours.ago)
    first_new = scheduled_run("wake", "failed", at: 27.hours.ago)
    bulk_runs("conversation", 2_001, from: 26.hours.ago, execution_state: "failed")
    newer = scheduled_run("wake", "failed", at: 1.hour.ago)

    streak = Agents::RunFailureStreak.call(@agent, kind: :scheduled)
    assert_not streak.truncated
    assert_equal first_new.id, streak.first_run_id
    ScheduledRunFailureNoticeJob.perform_now(newer.id)
    assert_equal success.id, recoveries.sole.data["run_id"]
    assert_equal first_new.id, failing_streaks.last.data["first_run_id"]
  end

  test "a failure the fields don't explain is said as unknown" do
    scheduled_run("wake", "failed", at: 2.hours.ago)
    run = scheduled_run("wake", "failed", at: 1.hour.ago)
    assert_equal "unknown", run.failure_category
    ScheduledRunFailureNoticeJob.perform_now(run.id)
    assert_includes notice_chat.messages.sole.content, "the run failed and the cause isn't identified"
  end

  test "nothing is said for a resident switched off, asleep for billing, or under a roll hold" do
    scheduled_run("wake", "failed", at: 2.hours.ago)
    run = scheduled_run("wake", "failed", at: 1.hour.ago)

    @agent.update!(active: false)
    ScheduledRunFailureNoticeJob.perform_now(run.id)
    assert_empty failing_streaks

    @agent.update!(active: true)
    ResidentEntitlement.create!(agent: @agent, account: @agent.account, source: "stripe", state: "held", held_at: Time.current, tier: "conversation")
    ScheduledRunFailureNoticeJob.perform_now(run.id)
    assert_empty failing_streaks
    ResidentEntitlement.where(agent: @agent).update_all(state: "active", held_at: nil)

    AuditLog.create!(user: nil, account: @agent.account, action: ResidentSwitchedOffNotice::SWITCHED_OFF, auditable: @agent, data: {})
    ScheduledRunFailureNoticeJob.perform_now(run.id)
    assert_empty failing_streaks
  end

  test "a conversation run's room notice uses the same authentication line" do
    first = conversation_run("failed", at: 2.hours.ago)
    run = conversation_run("failed", at: 1.hour.ago, response_body: { "status" => "error", "error_kind" => "auth_expired" })
    RunFailureNoticeJob.perform_now(run.id)
    assert_equal "#{@agent.name} couldn't respond here: the run's output looked like an authentication error (2nd failed run in a row since #{first.started_at.in_time_zone('Madrid').strftime('%H:%M %Z')}).",
      @room.messages.where(role: "system").last.content
  end

  test "this reads terminal failed runs only: a completed run whose hooks failed is a completion" do
    scheduled_run("wake", "failed", at: 3.hours.ago)
    second = scheduled_run("wake", "failed", at: 2.hours.ago)
    ScheduledRunFailureNoticeJob.perform_now(second.id)
    hooks_failed = scheduled_run("wake", "completed", at: 1.hour.ago, response_body: { "status" => "ok", "hook_errors" => [ "stop" ] })
    ScheduledRunFailureNoticeJob.perform_now(hooks_failed.id)
    assert_equal 1, recoveries.count, "hook health inside a run is not what this notice claims to know"
  end

  private

  def failing_streaks
    AuditLog.where(action: ScheduledRunFailureNotice::FAILING, auditable: @agent).order(:id)
  end

  def recoveries
    AuditLog.where(action: ScheduledRunFailureNotice::RECOVERED, auditable: @agent).order(:id)
  end

  def notice_chat
    streak = failing_streaks.last
    streak && Chat.find(streak.data.fetch("chat_id"))
  end

  def running_run(kind, chat: nil)
    AgentRuntimeInteraction.create!(
      agent: @agent, chat: chat, trigger_kind: kind, requested_by: "souls.house",
      session_id: "s", started_at: Time.current, run_id: SecureRandom.uuid,
      execution_state: "running", execution_deadline_at: 10.minutes.from_now
    )
  end

  # Scheduled runs in prod are not live-activity runs: execution_state stays
  # nil and the outcome is read from runtime_status, returncode and transport
  # status (chat_activity_status). "failed" here means that shape, with the
  # structured fields the caller passes; "completed" means a clean 200.
  def scheduled_run(kind, outcome, at:, **attrs)
    fields = outcome == "completed" ? { transport_status: 200, runtime_status: "ok", runtime_returncode: 0 } : { transport_status: 500 }
    AgentRuntimeInteraction.create!(
      { agent: @agent, chat: nil, trigger_kind: kind, requested_by: "souls.house scheduled wake",
        session_id: "#{@agent.uuid}-wake", started_at: at - 2.minutes, run_id: SecureRandom.uuid,
        finished_at: at, created_at: at - 2.minutes }.merge(fields).merge(attrs)
    )
  end

  # Many finished runs at once, a minute apart from `from`, without callbacks.
  def bulk_runs(kind, count, from:, **attrs)
    rows = Array.new(count) do |i|
      at = from + i.minutes
      { agent_id: @agent.id, trigger_kind: kind, requested_by: "souls.house", session_id: "s", run_id: SecureRandom.uuid,
        started_at: at - 30.seconds, finished_at: at, created_at: at, updated_at: at }.merge(attrs)
    end
    AgentRuntimeInteraction.insert_all!(rows)
  end

  def conversation_run(state, at:, **attrs)
    AgentRuntimeInteraction.create!(
      agent: @agent, chat: @room, trigger_kind: "conversation", requested_by: "souls.house",
      session_id: "s", started_at: at - 2.minutes, run_id: SecureRandom.uuid,
      execution_state: state, finished_at: at, created_at: at - 2.minutes, **attrs
    )
  end

end
