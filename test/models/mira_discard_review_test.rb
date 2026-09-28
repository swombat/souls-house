require "test_helper"
class MiraDiscardReviewTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @user = users(:user_1)
    @chat = @agent.account.chats.create!(model_id: "openrouter/auto", title: "Review discard", initiated_by_agent: @agent)
    @chat.agents << @agent
  end
  test "discarding a reply must not manufacture unanswered attention" do
    @chat.messages.create!(role: "user", user: @user, content: "Question", created_at: 2.hours.ago)
    answer = @chat.messages.create!(role: "assistant", agent: @agent, content: "Answer", created_at: 1.hour.ago)
    assert_not AgentAttentionFeed.new(@agent).call[:items].any? { |i| i[:thread_id] == @chat.to_param }
    answer.discard!
    assert_not AgentAttentionFeed.new(@agent).call[:items].any? { |i| i[:thread_id] == @chat.to_param }, "already answered question returned as attention"
  end
  test "discarding a human reply must not make an initiated chat never answered" do
    reply = @chat.messages.create!(role: "user", user: @user, content: "I replied")
    assert_not Chat.awaiting_human_response.exists?(@chat.id)
    reply.discard!
    assert_not Chat.awaiting_human_response.exists?(@chat.id), "historical response was forgotten"
  end
  test "discard progress seam must advance the changed preceding message revision" do
    run = AgentRuntimeInteraction.create!(agent: @agent, chat: @chat, trigger_kind: "conversation", session_id: "review", requested_by: "test", started_at: 1.minute.ago)
    progress = @chat.messages.create!(role: "assistant", agent: @agent, runtime_interaction: run, content: "Working")
    interruption = @chat.messages.create!(role: "user", user: @user, content: "Interrupting")
    old_revision = progress.revision
    interruption.discard!
    assert progress.reload.progress_break_after?
    assert_operator progress.revision, :>, old_revision, "client-visible seam changed without a sync revision"
  end

end
