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
    first = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Reviewer")
    second = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Daniel")
    assert_equal first, second
    assert_equal [ 2, "Daniel" ], [ second.requests_count, second.requested_by ]
  end

  test "release waits while the resident is still busy" do
    AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat)
    wake = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Reviewer")
    assert_nil PendingWake.release!(chat: @chat, agent: @resident)
    assert PendingWake.open.exists?(wake.id)
  end

  test "release drops a wake whose messages the finished run already saw" do
    message = @chat.messages.create!(role: "assistant", agent: @sibling, content: "Review posted early")
    run = finished_run(last_included_message_id: message.id)
    wake = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Reviewer")
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
    wake = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Reviewer")

    PendingWake.release!(chat: @chat, agent: @resident)
    assert_equal "nothing_new", wake.reload.drop_reason
  end

  test "release wakes once when a message arrived after the cursor" do
    seen = @chat.messages.create!(role: "assistant", agent: @sibling, content: "Earlier")
    finished_run(last_included_message_id: seen.id)
    @chat.messages.create!(role: "assistant", agent: @sibling, content: "Review posted mid-run")
    wake = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Reviewer")

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
    wake = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Reviewer")
    wake.update_columns(last_requested_at: (PendingWake::EXPIRY + 1.minute).ago)
    PendingWake.release!(chat: @chat, agent: @resident)
    assert_equal "expired", wake.reload.drop_reason

    @resident.update!(paused: true)
    paused = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Reviewer")
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
      @chat.queue_wakes_for_busy!([ @resident ], requested_by: "a mention from Daniel")
    end
    assert PendingWake.open.exists?(chat: @chat, agent: @resident)
  end

  test "the released run's prompt says why it woke" do
    @chat.messages.create!(role: "user", user: @user, content: "Over to you")
    wake = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "Reviewer")
    run = AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat)
    wake.update!(released_at: Time.current, released_interaction: run)

    request = ExternalAgentResponseRequest.new(agent: @resident, chat: @chat, interaction: run)
    assert_equal wake.prompt_note, request.send(:queued_wake_text)
    assert_nil ExternalAgentResponseRequest.new(agent: @resident, chat: @chat).send(:queued_wake_text)
  end

  private

  def finished_run(last_included_message_id:)
    run = AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat)
    run.update_columns(last_included_message_id: last_included_message_id, transport_status: 200, runtime_status: "ok")
    run.finish_execution!("completed")
    run
  end

end
