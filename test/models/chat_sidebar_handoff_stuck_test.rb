require "test_helper"

# A conversation stuck at the resident handoff limit shows a red hand in the
# sidebar, in the commitment clock's place (Daniel, 11 Nov, jaMvBj).
class ChatSidebarHandoffStuckTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @lume = agents(:research_assistant)
    @mira = agents(:code_reviewer)
    @account = @lume.account
    @chat = @account.chats.create!(manual_responses: true, agents: [ @lume, @mira ])
    @other = @account.chats.create!(manual_responses: true, agents: [ @lume, @mira ])
  end

  test "a request refused at the loop cap since the last person's message marks the conversation" do
    @chat.messages.create!(role: "user", user: @user, content: "Go on, both of you")
    refuse(@chat)

    assert_equal true, sidebar(@chat)["handoff_stuck"]
    assert_equal false, sidebar(@other)["handoff_stuck"]
  end

  test "a person posting clears it" do
    refuse(@chat)
    assert_equal true, sidebar(@chat)["handoff_stuck"]

    @chat.messages.create!(role: "user", user: @user, content: "Carry on")
    assert_equal false, sidebar(@chat)["handoff_stuck"]
  end

  test "a refused request that a later run read after all does not mark it" do
    handoff = refuse(@chat)
    handoff.update!(status: "delivered")
    assert_equal false, sidebar(@chat)["handoff_stuck"]
  end

  test "other refusals do not mark it" do
    refuse(@chat, reason: MessageHandoff::HANDOFFS_OFF_REASON)
    refuse(@chat, reason: "not_in_room")
    assert_equal false, sidebar(@chat)["handoff_stuck"]
  end

  test "the real loop guard marks it once the cap is spent" do
    @account.update!(resident_handoff_cap: 1)
    @chat.messages.create!(role: "user", user: @user, content: "Start")
    first = @chat.messages.create!(role: "assistant", agent: @lume, content: "Over to you")
    assert_equal "pending", MessageHandoff.accept!(message: first, explicit_ids: [ @mira.id ]).first.status
    assert_equal false, sidebar(@chat)["handoff_stuck"]

    second = @chat.messages.create!(role: "assistant", agent: @mira, content: "And back")
    assert_equal MessageHandoff::LOOP_CAP_REASON, MessageHandoff.accept!(message: second, explicit_ids: [ @lume.id ]).first.reason
    assert_equal true, sidebar(@chat)["handoff_stuck"]
  end

  private

  def refuse(chat, reason: MessageHandoff::LOOP_CAP_REASON)
    message = chat.messages.create!(role: "assistant", agent: @lume, content: "Mira, review please (#{reason})")
    MessageHandoff.create!(chat: chat, message: message, requester_agent: @lume, recipient_agent: @mira,
      source: "field", status: "blocked", reason: reason)
  end

  def sidebar(chat)
    Chat.sidebar_json_for([ chat ]).first
  end

end
