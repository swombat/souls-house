require "test_helper"

class FollowThroughCheckJobTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @other = agents(:code_reviewer)
    @agent.update!(
      runtime: "external", uuid: SecureRandom.uuid_v7, endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid", health_state: "healthy", consecutive_health_failures: 0
    )
    @chat = @agent.account.chats.create!(title: "Follow-through", manual_responses: true, agents: [ @agent, @other ])
    @previous_setting = ENV["SOULSHOUSE_FOLLOW_THROUGH"]
    ENV["SOULSHOUSE_FOLLOW_THROUGH"] = @agent.to_param
    @run = finished_run
  end

  teardown do
    ENV["SOULSHOUSE_FOLLOW_THROUGH"] = @previous_setting
  end

  test "ending a conversation run queues one check a minute later" do
    run = running_run
    assert_enqueued_with(job: FollowThroughCheckJob, args: [ run.id ]) do
      run.finish_execution!("completed")
    end
    job = enqueued_jobs.find { |j| j["job_class"] == "FollowThroughCheckJob" }
    assert_in_delta 60.seconds.from_now.to_f, job["scheduled_at"].then { |t| Time.zone.parse(t.to_s).to_f }, 5
  end

  test "failed and timed-out runs are checked; cancelled, busy and lost-contact runs are not" do
    %w[failed timed_out].each do |state|
      assert_enqueued_with(job: FollowThroughCheckJob) { running_run.finish_execution!(state) }
    end
    %w[cancelled busy outcome_unknown].each do |state|
      assert_no_enqueued_jobs(only: FollowThroughCheckJob) { running_run.finish_execution!(state) }
    end
  end

  test "the check is opt-in per resident" do
    [ nil, "", @other.to_param ].each do |setting|
      with_env("SOULSHOUSE_FOLLOW_THROUGH" => setting) do
        assert_no_enqueued_jobs(only: FollowThroughCheckJob) { running_run.finish_execution!("completed") }
      end
    end
    [ "all", "#{@other.to_param}, #{@agent.to_param}" ].each do |setting|
      with_env("SOULSHOUSE_FOLLOW_THROUGH" => setting) do
        assert_enqueued_with(job: FollowThroughCheckJob) { running_run.finish_execution!("completed") }
      end
    end
  end

  test "an announced step left undone gets one visible nudge run that carries its origin" do
    first = say("On it. I'll post the PR link here.")
    @chat.messages.create!(role: "assistant", agent: @other, content: "Sounds good.")
    second = say("Starting the branch now.", at: @run.started_at + 2.seconds)
    seen = nil
    UtilityInference.stub :decide, ->(state:, questions:) {
      seen = state
      { FollowThroughCheck::QUESTION_KEY => 0.9 }
    } do
      assert_enqueued_with(job: ManualAgentResponseJob) { perform }
    end

    assert_equal [ first.obfuscated_id, second.obfuscated_id ], seen[:run_messages].pluck(:id)
    assert_equal [ "Sounds good." ], seen[:others_during_run].pluck(:content)
    nudge = @chat.agent_runtime_interactions.find_by!(follow_through_of: @run)
    assert_equal "queued", nudge.execution_state
    assert_match "Follow-through check", @chat.messages.where(role: "user").last.content
    assert @run.reload.follow_through_checked_at?
  end

  test "a clear verdict does nothing visible" do
    say("Merged, CI green.")
    UtilityInference.stub :decide, ->(**) { { FollowThroughCheck::QUESTION_KEY => 0.2 } } do
      assert_no_difference(-> { Message.count }) do
        assert_no_difference(-> { AgentRuntimeInteraction.count }) { perform }
      end
    end
    assert @run.reload.follow_through_checked_at?
  end

  test "a run that posted nothing is not sent to Jev" do
    UtilityInference.stub :decide, ->(**) { flunk "nothing to judge" } do
      perform
    end
    assert @run.reload.follow_through_checked_at?
  end

  test "a retried check never nudges twice" do
    say("I'll knock Mira now.")
    UtilityInference.stub :decide, ->(**) { { FollowThroughCheck::QUESTION_KEY => 0.9 } } do
      perform
      perform
      assert_equal 1, AgentRuntimeInteraction.where(follow_through_of: @run).count

      # Even with the claim lost, the unique index holds and the room shows no second notice.
      @chat.agent_runtime_interactions.find_by!(follow_through_of: @run).finish_execution!("completed")
      @run.update_column(:follow_through_checked_at, nil)
      assert_no_difference(-> { Message.count }) { perform }
    end
    assert_equal 1, AgentRuntimeInteraction.where(follow_through_of: @run).count
  end

  test "a nudge run that still leaves the step undone is flagged, not woken again" do
    origin = @run
    @run = finished_run(follow_through_of: origin)
    say("Checking now.")
    UtilityInference.stub :decide, ->(state:, **) {
      assert state[:run][:started_by_follow_through_nudge]
      { FollowThroughCheck::QUESTION_KEY => 0.9 }
    } do
      assert_no_difference(-> { AgentRuntimeInteraction.count }) do
        assert_no_enqueued_jobs(only: ManualAgentResponseJob) { perform }
      end
    end
    assert_match "needs a person's eye", @chat.messages.last.content
  end

  test "a resident busy in this room is waited for, not skipped" do
    say("I'll open the PR.")
    running_run
    UtilityInference.stub :decide, ->(**) { flunk "must wait for the active run" } do
      assert_enqueued_with(job: FollowThroughCheckJob, args: [ @run.id, { deferrals: 1 } ]) { perform }
    end
    assert_not @run.reload.follow_through_checked_at?
  end

  test "a resident busy in another room does not delay this room's check" do
    say("I'll open the PR.")
    elsewhere = @agent.account.chats.create!(title: "Elsewhere", manual_responses: true, agents: [ @agent ])
    running_run(chat: elsewhere)
    UtilityInference.stub :decide, ->(**) { { FollowThroughCheck::QUESTION_KEY => 0.2 } } do
      perform
    end
    assert @run.reload.follow_through_checked_at?
  end

  test "a later silent run does not erase an earlier promise" do
    say("I'll open the PR.")
    later = finished_run(started_at: 10.seconds.ago)
    later.update!(execution_state: "failed")
    calls = 0
    UtilityInference.stub :decide, ->(state:, **) {
      calls += 1
      assert_equal [ "I'll open the PR." ], state[:run_messages].pluck(:content)
      { FollowThroughCheck::QUESTION_KEY => 0.9 }
    } do
      perform
    end
    assert_equal 1, calls
    assert AgentRuntimeInteraction.exists?(follow_through_of: @run)
  end

  test "a later run that lost contact recently is waited for" do
    say("I'll open the PR.")
    finished_run(started_at: 10.seconds.ago).update!(execution_state: "outcome_unknown", finished_at: 5.seconds.ago)
    UtilityInference.stub :decide, ->(**) { flunk "may still be working" } do
      assert_enqueued_with(job: FollowThroughCheckJob, args: [ @run.id, { deferrals: 1 } ]) { perform }
    end
  end

  test "a cancellation arriving during inference stops the old verdict" do
    say("I'll merge once CI is green.")
    UtilityInference.stub :decide, ->(**) {
      @chat.messages.create!(role: "user", user: users(:user_1), content: "Stop, don't merge that.")
      { FollowThroughCheck::QUESTION_KEY => 0.9 }
    } do
      assert_enqueued_with(job: FollowThroughCheckJob, args: [ @run.id, { deferrals: 1 } ]) { perform }
    end
    assert_not AgentRuntimeInteraction.exists?(follow_through_of: @run)
    assert_not @run.reload.follow_through_checked_at?
    assert_no_match "Follow-through", @chat.messages.last.content
  end

  test "a failure while acting leaves the run unchecked, so a retry acts" do
    say("I'll knock Mira now.")
    UtilityInference.stub :decide, ->(**) { { FollowThroughCheck::QUESTION_KEY => 0.9 } } do
      AgentRuntimeInteraction.stub :reserve!, ->(**) { raise ActiveRecord::StatementInvalid, "connection lost" } do
        assert_raises(ActiveRecord::StatementInvalid) { perform }
      end
      assert_not @run.reload.follow_through_checked_at?
      assert_no_match "Follow-through", @chat.messages.last.content
      perform
    end
    assert @run.reload.follow_through_checked_at?
    assert AgentRuntimeInteraction.exists?(follow_through_of: @run)
  end

  test "a nudge run that fails silently is flagged once and never woken" do
    say("On it. I'll post the PR link here.")
    origin = @run
    @run = finished_run(follow_through_of: origin, started_at: 2.minutes.ago)
    @run.update!(execution_state: "failed")
    UtilityInference.stub :decide, ->(state:, **) {
      assert_empty state[:run_messages]
      assert_equal [ "On it. I'll post the PR link here." ], state[:original_run_messages].pluck(:content)
      { FollowThroughCheck::QUESTION_KEY => 0.9 }
    } do
      assert_no_difference(-> { AgentRuntimeInteraction.count }) do
        assert_no_enqueued_jobs(only: ManualAgentResponseJob) { perform; perform }
      end
    end
    assert_equal 1, @chat.messages.where("content LIKE ?", "%needs a person's eye%").count
  end

  test "a nudge that never got to run is still flagged" do
    say("On it.")
    nudge = finished_run(follow_through_of: @run, started_at: 2.minutes.ago)
    nudge.update!(execution_state: "cancelled")
    assert FollowThroughCheck.checkable?(nudge)
    assert_not FollowThroughCheck.checkable?(finished_run.tap { |r| r.update!(execution_state: "cancelled") })
  end

  test "a resident who can't be woken gets no notice claiming they were" do
    say("I'll open the PR.")
    @agent.update!(paused: true)
    UtilityInference.stub :decide, ->(**) { { FollowThroughCheck::QUESTION_KEY => 0.9 } } do
      assert_no_difference(-> { Message.count }) { perform }
    end
  end

  test "the nudge run is told what it is and that it adds no authority" do
    say("On it. I'll post the PR link here.")
    nudge = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat, follow_through_of: @run)
    request = ExternalAgentResponseRequest.new(agent: @agent, chat: @chat, interaction: nudge)
    text = request.send(:request_text)
    assert_includes text, "FOLLOW-THROUGH CHECK"
    assert_includes text, "I'll post the PR link here."
    assert_includes text, "grants no new permissions"
    assert_not_includes text, "pressed the agent button"
  end

  private

  def perform(deferrals: 0)
    FollowThroughCheckJob.perform_now(@run.id, deferrals: deferrals)
  end

  def say(content, at: nil)
    message = @chat.messages.create!(role: "assistant", agent: @agent, content: content, runtime_interaction: @run)
    message.update_columns(created_at: at) if at
    message
  end

  def finished_run(follow_through_of: nil, started_at: 5.minutes.ago)
    AgentRuntimeInteraction.create!(
      agent: @agent, chat: @chat, trigger_kind: "conversation", requested_by: "souls.house",
      session_id: "#{@agent.uuid}-#{@chat.id}", started_at: started_at, run_id: SecureRandom.uuid,
      execution_state: "completed", finished_at: started_at + 1.minute, follow_through_of: follow_through_of
    )
  end

  def running_run(chat: @chat)
    AgentRuntimeInteraction.create!(
      agent: @agent, chat: chat, trigger_kind: "conversation", requested_by: "souls.house",
      session_id: "#{@agent.uuid}-#{chat.id}", started_at: Time.current, run_id: SecureRandom.uuid,
      execution_state: "running", execution_deadline_at: 10.minutes.from_now
    )
  end

  def with_env(values)
    old = values.to_h { |k, _| [ k, ENV[k] ] }
    values.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

end
