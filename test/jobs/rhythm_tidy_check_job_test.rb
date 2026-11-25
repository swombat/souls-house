require "test_helper"

class RhythmTidyCheckJobTest < ActiveSupport::TestCase

  setup do
    @first = agents(:research_assistant)
    @second = agents(:code_reviewer)
    [ @first, @second ].each do |agent|
      agent.update!(
        runtime: "external", uuid: SecureRandom.uuid_v7, endpoint_url: "https://agent.example.com",
        trigger_bearer_token: "tr_valid", health_state: "healthy", consecutive_health_failures: 0
      )
    end
    @account = @first.account
    @done = @account.visual_tags.create!(label: "Done", icon: "Check", colour: "rose", hides_from_list: true)
    @rhythm = Rhythm.create!(
      account: @account, creator: users(:user_1), title: "Field notes",
      opening: "What came in?", cadence: "daily", time_of_day: "09:00", timezone: "UTC",
      agents: [ @first, @second ]
    )
    @occurrence = @rhythm.fire!(manual: true, request_key: "tidy").occurrence
    # A scheduled run: manual runs are never asked about.
    @occurrence.update_columns(manual: false, request_key: nil)
    @chat = @occurrence.chat
    @dispatch = @occurrence.message_dispatch
    MessageDispatchJob.perform_now(@dispatch)
    @runs = @dispatch.reload.runtime_interactions.index_by(&:agent_id)
    assert_equal 2, @runs.size
  end

  test "a finished run in a rhythm chat queues the check; a settled run doesn't" do
    assert_enqueued_with(job: RhythmTidyCheckJob, args: [ @occurrence.id ]) do
      run_of(@first).finish_execution!("completed")
    end
    @occurrence.update!(tidy_asked_at: Time.current)
    assert_no_enqueued_jobs(only: RhythmTidyCheckJob) { run_of(@second).finish_execution!("completed") }
  end

  test "once the opening round is over, the last finisher is woken once with the question" do
    finish(run_of(@second), at: 2.minutes.ago)
    finish(run_of(@first), at: 1.minute.ago)

    assert_enqueued_with(job: ManualAgentResponseJob) { perform }
    wake = @occurrence.reload.tidy_interaction
    assert @occurrence.tidy_asked_at?
    assert_equal @first, wake.agent
    assert_equal "queued", wake.execution_state
    assert_equal @occurrence, RhythmTidy.for_interaction(wake)

    text = ExternalAgentResponseRequest.new(agent: @first, chat: @chat, requested_by: "souls.house", interaction: wake)
      .send(:trigger_intro_text)
    assert_match "RHYTHM TIDY-UP", text
    assert_match @done.to_param, text
    assert_match "/api/v1/conversations/#{@chat.to_param}/archive", text

    # Duplicates, and the wake's own run finishing, never ask again.
    assert_no_difference(-> { AgentRuntimeInteraction.count }) { perform }
    wake.finish_execution!("completed")
    assert_no_difference(-> { AgentRuntimeInteraction.count }) { perform }
  end

  test "a later peer turn does not inherit the question" do
    finish(run_of(@first), at: 3.minutes.ago)
    finish(run_of(@second), at: 2.minutes.ago)
    peer = AgentRuntimeInteraction.create!(
      agent: @first, chat: @chat, trigger_kind: "conversation", requested_by: "souls.house",
      session_id: "#{@first.uuid}-#{@chat.id}", started_at: 90.seconds.ago, run_id: SecureRandom.uuid,
      execution_state: "completed", finished_at: 1.minute.ago
    )
    assert_nil peer.message_dispatch

    perform
    assert_equal @second, @occurrence.reload.tidy_interaction.agent
  end

  test "nothing is asked or settled while a run is still going" do
    finish(run_of(@first))

    assert_no_difference(-> { AgentRuntimeInteraction.count }) { perform }
    assert_nil @occurrence.reload.tidy_asked_at
  end

  test "a person speaking, a tag or an open flag settles the run without asking" do
    finish_all
    @chat.messages.create!(role: "user", user: users(:user_1), content: "Nice, thanks.")
    assert_settled_without_wake

    reset!
    @chat.update!(visual_tag: @account.visual_tags.create!(label: "Input Required", icon: "Check", colour: "rose"))
    assert_settled_without_wake

    reset!
    said = @chat.messages.create!(role: "assistant", agent: @first, content: "Daniel, which one?")
    ReplyExpectation.create!(message: said, user: users(:user_1), score: 0.9, classifier_version: "test")
    assert_settled_without_wake
  end

  test "platform notices are not a person speaking" do
    finish_all
    @chat.messages.create!(role: "user", content: "[System Notice] Something happened.")

    perform
    assert @occurrence.reload.tidy_interaction
  end

  test "a one-resident run is never asked: it already stays off the list" do
    @chat.chat_agents.where(agent: @second).destroy_all
    finish(run_of(@first))
    assert_settled_without_wake
  end

  test "a paused last finisher is not woken, and the run is settled" do
    finish_all
    @second.update!(paused: true)
    assert_settled_without_wake
  end

  test "only the doors a resident has are offered: archive is home-only" do
    tidy = RhythmTidy.new(@occurrence)
    guest = agents(:other_account_agent)
    assert_match "visual_tag_id", tidy.ways_for(guest)
    assert_no_match "archive", tidy.ways_for(guest)
    @done.destroy!
    assert_equal "To archive it, POST /api/v1/conversations/#{@chat.to_param}/archive.", tidy.ways_for(@second)
    assert_nil tidy.ways_for(guest)
  end

  test "the wake does not start if the run became someone's after it was reserved" do
    finish_all
    perform
    wake = @occurrence.reload.tidy_interaction
    @chat.messages.create!(role: "user", user: users(:user_1), content: "Wait, I want to read this.")

    assert_not wake.claim_dispatch!
    assert_equal "cancelled", wake.reload.execution_state
  end

  test "the wake starts when nothing changed" do
    finish_all
    perform
    wake = @occurrence.reload.tidy_interaction

    assert wake.claim_dispatch!
    assert_not wake.claim_dispatch!
  end

  private

  def run_of(agent)
    @runs.fetch(agent.id)
  end

  def perform
    RhythmTidyCheckJob.perform_now(@occurrence.id)
  end

  def finish(run, at: Time.current)
    run.finish_execution!("completed")
    run.update_columns(finished_at: at)
  end

  def finish_all
    finish(run_of(@first), at: 2.minutes.ago)
    finish(run_of(@second), at: 1.minute.ago)
  end

  def reset!
    @chat.messages.where(role: "user").where.not(id: @occurrence.message_id).delete_all
    ReplyExpectation.joins(:message).where(messages: { chat_id: @chat.id }).delete_all
    @chat.update!(visual_tag: nil)
    @occurrence.update!(tidy_asked_at: nil, tidy_interaction: nil)
  end

  def assert_settled_without_wake
    assert_no_difference(-> { AgentRuntimeInteraction.count }) { perform }
    assert @occurrence.reload.tidy_asked_at?
    assert_nil @occurrence.tidy_interaction
  end

end
