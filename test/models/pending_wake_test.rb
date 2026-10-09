require "test_helper"

class PendingWakeTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @account = @user.personal_account
    @account.update!(use_system_ai_credentials: false, openrouter_api_key: "test-only-router")
    @resident = @account.agents.create!(name: "Busy", system_prompt: "Test", runtime: "external")
    @sibling = @account.agents.create!(name: "Reviewer", system_prompt: "Test", runtime: "external")
    @chat = @account.chats.new(title: "Two residents", manual_responses: true)
    @chat.agents = [ @resident, @sibling ]
    @chat.save!
  end

  test "queue coalesces into the one open wake" do
    first = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Reviewer", requester_agent: @sibling)
    second = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Daniel", user: @user)
    assert_equal first, second
    assert_equal [ 2, "Daniel" ], [ second.requests_count, second.requested_by ]
    assert_equal [ [ "trigger", nil, @sibling.id ], [ "trigger", @user.id, nil ] ],
                 second.sources.order(:id).pluck(:kind, :user_id, :requester_agent_id)
  end

  test "release waits while the resident is still busy" do
    AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat)
    wake = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Reviewer", requester_agent: @sibling)
    assert_nil PendingWake.release!(chat: @chat, agent: @resident)
    assert PendingWake.open.exists?(wake.id)
  end

  test "release drops a wake whose messages the finished run already saw" do
    message = @chat.messages.create!(role: "assistant", agent: @sibling, content: "Review posted early")
    run = finished_run(last_included_message_id: message.id)
    wake = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Reviewer", requester_agent: @sibling)
    wake.update_columns(last_requested_at: run.finished_at)

    assert_no_difference -> { AgentRuntimeInteraction.count } do
      PendingWake.release!(chat: @chat, agent: @resident)
    end
    assert_equal "nothing_new", wake.reload.drop_reason
  end

  test "release ignores the resident's own later messages when looking for something new" do
    seen = @chat.messages.create!(role: "assistant", agent: @sibling, content: "Review")
    finished_run(last_included_message_id: seen.id)
    @chat.messages.create!(role: "assistant", agent: @resident, content: "My own reply, after the cursor")
    wake = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Reviewer", requester_agent: @sibling)

    PendingWake.release!(chat: @chat, agent: @resident)
    assert_equal "nothing_new", wake.reload.drop_reason
  end

  test "release wakes once when a message arrived after the cursor" do
    seen = @chat.messages.create!(role: "assistant", agent: @sibling, content: "Earlier")
    finished_run(last_included_message_id: seen.id)
    @chat.messages.create!(role: "assistant", agent: @sibling, content: "Review posted mid-run")
    wake = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Reviewer", requester_agent: @sibling)

    AgentRuntimeInteraction.stub :live_activity_enabled?, true do
      assert_difference -> { AgentRuntimeInteraction.count }, 1 do
        PendingWake.release!(chat: @chat, agent: @resident)
      end
      assert_nil PendingWake.release!(chat: @chat, agent: @resident), "a released wake is not released twice"
    end
    wake.reload
    assert wake.released_at
    assert_equal @resident, wake.released_interaction.agent
    assert_match(/arrived here while you were already responding/, wake.prompt_note)
  end

  test "expired and paused wakes are dropped, not run" do
    @chat.messages.create!(role: "assistant", agent: @sibling, content: "Review")
    wake = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Reviewer", requester_agent: @sibling)
    wake.update_columns(last_requested_at: (PendingWake::EXPIRY + 1.minute).ago)
    PendingWake.release!(chat: @chat, agent: @resident)
    assert_equal "expired", wake.reload.drop_reason

    @resident.update!(paused: true)
    paused = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Reviewer", requester_agent: @sibling)
    assert_no_difference -> { AgentRuntimeInteraction.count } do
      PendingWake.release!(chat: @chat, agent: @resident)
    end
    assert_equal "paused", paused.reload.drop_reason
  end

  test "a busy run finishing between the busy check and the queue still leaves a release job" do
    run = AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat)
    run.finish_execution!("completed")
    @chat.messages.create!(role: "assistant", agent: @sibling, content: "Review")

    assert_enqueued_with(job: PendingWakeJob, args: [ @chat.id, @resident.id ]) do
      @chat.queue_wakes_for_busy!([ @resident ], requested_by: "a mention from Daniel", message: human_message)
    end
    assert PendingWake.open.exists?(chat: @chat, agent: @resident)
  end

  test "the released run's prompt says why it woke" do
    @chat.messages.create!(role: "user", user: @user, content: "Over to you")
    wake = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Reviewer", requester_agent: @sibling)
    run = AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat)
    wake.update!(released_at: Time.current, released_interaction: run)

    request = ExternalAgentResponseRequest.new(agent: @resident, chat: @chat, interaction: run)
    assert_equal wake.prompt_note, request.send(:queued_wake_text)
    assert_nil ExternalAgentResponseRequest.new(agent: @resident, chat: @chat).send(:queued_wake_text)
  end

  # Pause (Mira's review of #252): read fresh at release, and again before the
  # released run reaches the runtime.

  test "release reads pause fresh, not from the resident object it was handed" do
    @chat.messages.create!(role: "assistant", agent: @sibling, content: "Review")
    stale = Agent.find(@resident.id)
    Agent.where(id: @resident.id).update_all(paused: true)
    wake = PendingWake.queue!(chat: @chat, agent: stale, requested_by: "Reviewer", requester_agent: @sibling)

    assert_no_difference -> { AgentRuntimeInteraction.count } do
      PendingWake.release!(chat: @chat, agent: stale)
    end
    assert_equal "paused", wake.reload.drop_reason
  end

  test "a pause after release but before dispatch stops the released run" do
    run = released_run
    @resident.update!(paused: true)

    ManualAgentResponseJob.perform_now(@chat, @resident, runtime_interaction_id: run.id)
    assert_equal "cancelled", run.reload.execution_state
  end

  test "the released run's claim refuses a pause that landed after reservation" do
    run = released_run
    @resident.update!(paused: true)

    assert_not run.claim_dispatch!
    assert_equal "cancelled", run.reload.execution_state
    assert_equal "claim_refused:paused", run.released_pending_wake.drop_reason
  end

  # Source authority: a wake stands only while something that asked for it
  # still does.

  test "a busy sole-resident message wake is withdrawn when its message is discarded before release" do
    message = human_message
    wake = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "a message", message: message)
    message.discard!

    assert_no_difference -> { AgentRuntimeInteraction.count } do
      PendingWake.release!(chat: @chat, agent: @resident)
    end
    assert_equal "sources_withdrawn", wake.reload.drop_reason
  end

  test "a message wake is withdrawn when its author leaves the account" do
    wake = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "a message", message: human_message)
    Membership.where(user: @user, account: @account).delete_all

    PendingWake.release!(chat: @chat, agent: @resident)
    assert_equal "sources_withdrawn", wake.reload.drop_reason
  end

  test "a discard after reservation stops the released run at its claim" do
    message = human_message
    run = released_run(message: message)
    message.discard!

    assert_not run.claim_dispatch!
    assert_equal "cancelled", run.reload.execution_state
    assert_equal "claim_refused:sources_withdrawn", run.released_pending_wake.drop_reason
  end

  test "coalesced sources: the wake stands while any one of them does" do
    message = human_message
    PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "a message", message: message)
    wake = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Reviewer", requester_agent: @sibling)
    message.discard!
    assert wake.standing_source?

    @chat.agents.delete(@sibling)
    assert_not wake.reload.standing_source?, "a knocking resident removed from the room no longer stands"
  end

  test "a person's trigger stands while they are a member, not after" do
    wake = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Daniel", user: @user)
    assert wake.standing_source?
    Membership.where(user: @user, account: @account).delete_all
    assert_not wake.reload.standing_source?
  end

  test "an already claimed released run is not cancelled by a later refusal" do
    run = released_run
    assert run.claim_dispatch!
    @resident.update!(paused: true)

    assert_not run.claim_dispatch!
    assert_equal "preparing", run.reload.execution_state
    assert_nil run.released_pending_wake.dropped_at
  end

  private

  def human_message
    @chat.messages.create!(role: "user", user: @user, content: "Over to you")
  end

  # A wake released into a reserved, unclaimed run, with something new for
  # the resident to see.
  def released_run(message: nil)
    message ||= human_message
    PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "a message", message: message)
    AgentRuntimeInteraction.stub :live_activity_enabled?, true do
      PendingWake.release!(chat: @chat, agent: @resident)
    end
    PendingWake.find_by!(chat: @chat, agent: @resident).released_interaction
  end

  def finished_run(last_included_message_id:)
    run = AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat)
    run.update_columns(last_included_message_id: last_included_message_id, transport_status: 200, runtime_status: "ok")
    run.finish_execution!("completed")
    run
  end

end
