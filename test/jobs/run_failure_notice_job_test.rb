require "test_helper"

class RunFailureNoticeJobTest < ActiveSupport::TestCase

  SECRET_TEXT = "sk-ant-api03-SECRET /home/agent/identity/prompt.md provider 429 rate limited".freeze

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(runtime: "external", uuid: SecureRandom.uuid_v7, endpoint_url: "https://agent.example.com", trigger_bearer_token: "tr_valid")
    @chat = @agent.account.chats.create!(title: "Notices", manual_responses: true, agents: [ @agent ])
    owner = @agent.account.owner
    (owner.profile || owner.build_profile).update!(timezone: "Madrid")
  end

  test "a failed or timed-out conversation run queues the check; completed, busy and lost runs do not" do
    %w[failed timed_out].each do |state|
      assert_enqueued_with(job: RunFailureNoticeJob) { running_run.finish_execution!(state) }
    end
    %w[completed busy outcome_unknown cancelled].each do |state|
      assert_no_enqueued_jobs(only: RunFailureNoticeJob) { running_run.finish_execution!(state) }
    end
  end

  test "the first failure of a streak says nothing in the room" do
    run = failed_run(at: Time.zone.parse("2026-10-14 04:20 UTC"))
    assert_no_difference -> { @chat.messages.count } do
      RunFailureNoticeJob.perform_now(run.id)
    end
  end

  test "from the second failure on, the house says so once per run, with the streak and no reply wording" do
    failed_run(at: Time.zone.parse("2026-10-14 04:20 UTC"))
    failed_run(at: Time.zone.parse("2026-10-14 05:00 UTC"))
    third = failed_run(at: Time.zone.parse("2026-10-14 05:40 UTC"), runtime_status: "error", runtime_returncode: 1)

    assert_difference -> { @chat.messages.where(role: "system").count }, 1 do
      RunFailureNoticeJob.perform_now(third.id)
      RunFailureNoticeJob.perform_now(third.id)
    end
    notice = @chat.messages.where(role: "system").last
    assert_equal "#{@agent.name} couldn't respond here: the run ended in an error " \
      "(3rd failed run in a row since 06:19 CEST).", notice.content
    assert_nil notice.agent_id
    assert_equal notice.id, third.reload.failure_notice_message_id
    assert_equal "Why?", notice.notice_link["label"]
    assert_equal Rails.application.routes.url_helpers.edit_account_agent_path(@agent.account, @agent, tab: "interactions"),
      notice.notice_link["path"]
    assert_equal notice.notice_link, notice.as_json["notice_link"]
  end

  test "a reply that reached the room is never written over: the notice says the run failed after replying" do
    travel_to Time.zone.parse("2026-10-14 12:00 UTC")
    failed_run(at: 20.minutes.ago)
    run = failed_run(at: 1.minute.ago)
    @chat.messages.create!(role: "assistant", agent: @agent, content: "Here is my answer.", runtime_interaction: run)

    RunFailureNoticeJob.perform_now(run.id)
    assert_match(/\A#{@agent.name}'s run ended with an error after replying \(2nd failed run in a row since \d\d:\d\d CES?T\)\.\z/,
      @chat.messages.where(role: "system").last.content)
  end

  test "only a visible reply this run posted here counts as replying" do
    failed_run(at: 30.minutes.ago)
    run = failed_run(at: 10.minutes.ago)
    other_run = failed_run(at: 5.minutes.ago, state: "busy")
    other_room = @agent.account.chats.create!(title: "Elsewhere", manual_responses: true, agents: [ @agent ])
    # Another run's reply, after this one ended (a delayed notice must not count it).
    @chat.messages.create!(role: "assistant", agent: @agent, content: "A later reply.", runtime_interaction: other_run)
    # This run's rows that nobody saw as a reply.
    @chat.messages.create!(role: "assistant", agent: @agent, content: "Working on it", runtime_interaction: run, progress_message: true)
    @chat.messages.create!(role: "assistant", agent: @agent, content: "Half a rep", runtime_interaction: run, streaming: true)
    @chat.messages.create!(role: "assistant", agent: @agent, content: "   ", runtime_interaction: run)
    @chat.messages.create!(role: "assistant", agent: @agent, content: "Withdrawn", runtime_interaction: run).discard!
    other_room.messages.create!(role: "assistant", agent: @agent, content: "Wrong room", runtime_interaction: run)
    opening = @chat.messages.create!(role: "assistant", agent: @agent, content: "Good morning, what came in?", runtime_interaction: run)
    RhythmOccurrence.create!(chat: @chat, message: opening, creator_label: "Lume", title: "Field notes", rhythm_title: "Field notes",
      opening: "Good morning, what came in?", scheduled_for: 11.minutes.ago)

    assert_match(/\A#{@agent.name} couldn't respond here: /, notice_for(run))
  end

  test "duplicate finalization of a run still gives one notice" do
    failed_run(at: 20.minutes.ago)
    run = failed_run(at: 10.minutes.ago, state: "outcome_unknown")
    jobs = []
    RunFailureNoticeJob.stub(:perform_later, ->(id) { jobs << id }) do
      run.finish_execution!("failed")
      run.update!(finished_at: Time.current)
    end
    assert_equal [ run.id, run.id ], jobs
    assert_difference -> { @chat.messages.where(role: "system").count }, 1 do
      jobs.each { |id| RunFailureNoticeJob.perform_now(id) }
    end
  end

  test "a truncated streak is said as a lower bound with no start time" do
    failed_run(at: 30.minutes.ago)
    run = failed_run(at: 20.minutes.ago)
    truncated = Agents::RunFailureStreak::Result.new(count: 2, since: nil, categories: %w[unknown unknown], truncated: true)
    Agents::RunFailureStreak.stub(:call, truncated) do
      assert_match(/\(2 or more failed runs in a row\)\.\z/, notice_for(run))
    end
  end

  test "each category has its own plain cause, and unknown is said as unknown" do
    failed_run(at: 30.minutes.ago)
    assert_match(/couldn't respond here: the run timed out \(/, notice_for(failed_run(at: 25.minutes.ago, state: "timed_out")))
    assert_match(/couldn't respond here: its runtime couldn't be reached \(/,
      notice_for(failed_run(at: 20.minutes.ago, error_class: "Errno::ECONNREFUSED", error_message: SECRET_TEXT)))
    assert_match(/couldn't respond here: the run failed and the cause isn't identified \(/, notice_for(failed_run(at: 15.minutes.ago)))
  end

  test "no diagnostic text from the run ever reaches the notice" do
    failed_run(at: 30.minutes.ago, stderr: SECRET_TEXT, stdout: SECRET_TEXT, error_message: SECRET_TEXT)
    run = failed_run(at: 20.minutes.ago, stderr: SECRET_TEXT, stdout: SECRET_TEXT, error_class: "ClampRuntimeFailed",
      error_message: SECRET_TEXT, response_body: { "status" => "error", "stderr" => SECRET_TEXT }, runtime_status: "error", runtime_returncode: 2)

    content = notice_for(run)
    notice = @chat.messages.where(role: "system").last
    [ "sk-ant", "SECRET", "/home/agent", "429", "rate limited", "ClampRuntimeFailed", "returncode" ].each do |fragment|
      assert_not_includes content, fragment
      assert_not_includes notice.notice_link.to_json, fragment
    end
  end

  test "busy runs never get a notice, even inside a streak" do
    failed_run(at: 30.minutes.ago)
    failed_run(at: 20.minutes.ago)
    busy = failed_run(at: 10.minutes.ago, state: "busy")
    assert_no_difference -> { @chat.messages.count } do
      RunFailureNoticeJob.perform_now(busy.id)
    end
  end

  test "a guest resident's notice carries no link the room's people could not open" do
    other = accounts(:team_account)
    # A room in another account, where this resident is a guest.
    guest_room = other.chats.new(title: "Guest", manual_responses: true)
    guest_room.save!(validate: false)
    failed_run(at: 30.minutes.ago, chat: guest_room)
    run = failed_run(at: 20.minutes.ago, chat: guest_room)

    RunFailureNoticeJob.perform_now(run.id)
    notice = guest_room.messages.where(role: "system").last
    assert_match(/couldn't respond here/, notice.content)
    assert_nil notice.notice_link
  end

  private

  def notice_for(run)
    RunFailureNoticeJob.perform_now(run.id)
    @chat.messages.where(role: "system").order(:id).last.content
  end

  def running_run
    AgentRuntimeInteraction.create!(
      agent: @agent, chat: @chat, trigger_kind: "conversation", requested_by: "souls.house",
      session_id: "s", started_at: Time.current, run_id: SecureRandom.uuid,
      execution_state: "running", execution_deadline_at: 10.minutes.from_now
    )
  end

  def failed_run(at:, state: "failed", chat: @chat, **attrs)
    AgentRuntimeInteraction.create!(
      agent: @agent, chat: chat, trigger_kind: "conversation", requested_by: "souls.house",
      session_id: "s", started_at: at - 1.minute, run_id: SecureRandom.uuid,
      execution_state: state, finished_at: at, created_at: at - 1.minute, **attrs
    )
  end

end
