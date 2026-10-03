require "test_helper"

class MessageStoneRevisionTest < ActiveSupport::TestCase

  setup do
    @user = users(:confirmed_user)
    @agent = agents(:research_assistant)
    @chat = @agent.account.chats.create!(title: "References", model_id: "openrouter/auto", agents: [ @agent ])
    @stone = Stone.publish!(chat: @chat, title: "Referenced", html: "<!doctype html><html><body><p>Original</p></body></html>", author: @agent, public: true)
    @revision = @stone.latest_revision
    @message = @chat.messages.create!(role: "assistant", content: "See this", agent: @agent)
  end

  test "a message references a unique specific revision and indicates newer revisions without repointing" do
    @message.stone_revisions << @revision
    assert_not @message.message_stone_revisions.build(stone_revision: @revision).valid?
    @message.reload
    card = @message.stones_json.first
    assert_equal @revision.to_param, card[:id]
    assert_equal "/stones/#{@stone.public_token}/revisions/1", card[:url]
    assert_equal "/stones/#{@stone.public_token}", card[:latest_url]
    assert_not card[:newer_revision_available]
    @stone.revise!(title: "Newer", html: "<!doctype html><html><body><p>Newer</p></body></html>", author: @user, public: true, base_revision_id: @revision.to_param)
    card = @message.reload.stones_json.first
    assert card[:newer_revision_available]
    assert_equal "Referenced", card[:title]
    assert_equal 1, card[:number]
    assert_equal 1, @message.as_json["stones_json"].length
  end

  test "cross conversation references and new withdrawn references are rejected" do
    other_chat = @agent.account.chats.create!(title: "Other", model_id: "openrouter/auto", agents: [ @agent ])
    other_message = other_chat.messages.create!(role: "assistant", content: "Wrong room", agent: @agent)
    assert_not other_message.message_stone_revisions.build(stone_revision: @revision).valid?
    @message.stone_revisions << @revision
    @stone.withdraw!
    assert @message.reload.stones_json.first[:withdrawn]
    assert_not other_chat.messages.create!(role: "assistant", content: "No new link", agent: @agent).message_stone_revisions.build(stone_revision: @revision).valid?
    assert_not @chat.messages.create!(role: "assistant", content: "No new link", agent: @agent).message_stone_revisions.build(stone_revision: @revision).valid?
  end

  test "deleting a message removes links without deleting the stone" do
    @message.stone_revisions << @revision
    assert_difference "MessageStoneRevision.count", -1 do
      assert_no_difference [ "Stone.count", "StoneRevision.count" ] do
        @message.destroy!
      end
    end
  end

end
