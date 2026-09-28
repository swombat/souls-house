require "test_helper"

# Issue #94, PR B step 2 (#92): deleting a message discards it. The row and
# its content stay, restorable by an admin, and every transcript reader hides
# it. The resident-context checks are the ones a resident would feel.
class MessageDiscardTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @chat = @agent.account.chats.create!(model_id: "openrouter/auto", title: "Discard probe")
    @kept = @chat.messages.create!(role: "user", content: "Still here")
    @gone = @chat.messages.create!(role: "user", content: "Deleted words")
    @gone.discard!
  end

  test "hidden from the web transcript" do
    page = @chat.messages_page
    assert_includes page, @kept
    assert_not_includes page, @gone
    assert_equal 1, @chat.message_count
  end

  test "hidden from the agent API transcript" do
    bodies = @chat.transcript_for_api.map { |message| message[:content] || message["content"] }
    assert_includes bodies, "Still here"
    assert_not_includes bodies, "Deleted words"
  end

  test "hidden from a resident's full-window context" do
    text = ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).send(:request_text)
    assert_includes text, "Still here"
    refute_includes text, "Deleted words"
    refute_includes text, @gone.obfuscated_id
  end

  test "hidden from a resident's persistent-session delta" do
    @agent.update!(persistent_session: true)
    AgentRuntimeInteraction.create!(
      agent: @agent, chat: @chat, trigger_kind: "conversation", session_id: "s",
      requested_by: "test", started_at: 1.minute.ago, last_included_message_id: @kept.id,
      chaos_session_id: "chaos-1", transport_status: 200, runtime_status: "ok"
    )
    later = @chat.messages.create!(role: "user", content: "After the cursor")
    @chat.messages.create!(role: "user", content: "Deleted after the cursor").discard!

    request = ExternalAgentResponseRequest.new(agent: @agent, chat: @chat)
    delta = request.send(:request_delta_text)

    assert_includes delta, "After the cursor"
    refute_includes delta, "Deleted after the cursor"
    assert_includes delta, "message_count_included: 1"
    assert_equal later.id, request.send(:computed_last_included_message_id)
  end

  test "hidden from search and not copied into a fork" do
    assert_empty Message.search_in_account(@chat.account, "Deleted words")
    forked = @chat.fork_with_title!("Fork")
    assert_equal [ "Still here" ], forked.messages.pluck(:content)
  end

  test "an identical message can be sent again after the last one was deleted" do
    @chat.messages.where(id: @kept.id).update_all(discarded_at: Time.current)
    assert @chat.messages.create!(role: "user", content: "Deleted words").persisted?
  end

  test "restore brings it back with a new revision" do
    revision = @gone.reload.revision
    @gone.undiscard!

    assert_operator @gone.reload.revision, :>, revision
    assert_includes @chat.messages_page, @gone
    assert_includes ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).send(:request_text), "Deleted words"
  end

  test "discard keeps a progress seam like destroy did" do
    run = AgentRuntimeInteraction.create!(agent: @agent, chat: @chat, trigger_kind: "conversation",
      session_id: "p", requested_by: "test", started_at: 1.minute.ago)
    progress = @chat.messages.create!(role: "assistant", agent: @agent, runtime_interaction: run, content: "Working")
    interruption = @chat.messages.create!(role: "user", content: "Interrupting")

    interruption.discard!

    assert progress.reload.progress_break_after?
  end

end
