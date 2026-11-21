require "test_helper"

# Private conversations (eKmnrJ): one audience rule, Chat.visible_to.
class ChatPrivateTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:team_account)
    @owner = @account.memberships.find_by!(role: "owner").user # account admin
    @creator = @account.memberships.find_by!(role: "member").user
    @inside = @account.agents.create!(name: "Inside", runtime: "external", model_id: "openrouter/auto", system_prompt: "x")
    @outside = @account.agents.create!(name: "Outside", runtime: "external", model_id: "openrouter/auto", system_prompt: "x")
    @chat = @account.chats.create_with_message!({ title: "Just us", private: true, manual_responses: true },
      user: @creator, agent_ids: [ @inside.id ], automatic_response: false)
    @open = @account.chats.create_with_message!({ title: "Everyone", manual_responses: true },
      user: @creator, agent_ids: [ @inside.id ], automatic_response: false)
  end

  test "the creator is in it from the start, before posting" do
    assert @chat.visible_to?(@creator)
    assert_equal [ "creator" ], @chat.chat_participants.pluck(:source)
    assert_includes Chat.visible_to(@creator), @chat
  end

  test "a seated resident sees it; an unseated one doesn't" do
    assert @chat.visible_to?(@inside)
    refute @chat.visible_to?(@outside)
    refute_includes Chat.visible_to(@outside), @chat
    assert_includes Chat.visible_to(@outside), @open
  end

  test "an account admin who isn't in it sees nothing, and neither does a site admin" do
    refute @chat.visible_to?(@owner)
    refute_includes @account.chats.visible_to(@owner), @chat
    assert_includes @account.chats.visible_to(@owner), @open
    refute @chat.accessible_by?(@owner)

    @owner.update_columns(is_site_admin: true)
    refute @chat.accessible_by?(@owner.reload)
    assert @open.accessible_by?(@owner)
  end

  test "nobody outside it can post into it, by any path" do
    message = @chat.messages.new(role: "user", content: "let me in", user: @owner)
    refute message.valid?
    assert_includes message.errors.full_messages, "This conversation is private"

    resident = @chat.messages.new(role: "assistant", content: "hello", agent: @outside)
    refute resident.valid?

    assert @chat.messages.new(role: "user", content: "still me", user: @creator).valid?
    assert @chat.messages.new(role: "assistant", content: "hi", agent: @inside).valid?
  end

  test "losing the account drops access but keeps the posts and the place" do
    @chat.messages.create!(role: "user", content: "mine", user: @creator)
    @account.memberships.find_by!(user: @creator).destroy!

    refute Chat.app_accessible_to(@creator).exists?(@chat.id)
    assert @chat.chat_participants.exists?(user: @creator)
    assert @chat.messages.exists?(user: @creator)
  end

  test "search leaves out private chats the viewer isn't in" do
    @chat.messages.create!(role: "user", content: "pomegranate", user: @creator)
    @open.messages.create!(role: "user", content: "pomegranate too", user: @creator)

    assert_equal 2, Message.search_in_account(@account, "pomegranate", viewer: @creator).count
    assert_equal [ @open.id ], Message.search_in_account(@account, "pomegranate", viewer: @owner).map(&:chat_id)
    assert_equal [ @open.id ], Message.search_in_account(@account, "pomegranate").map(&:chat_id)
  end

  test "the sidebar shape says it is private" do
    assert_equal true, @chat.as_json(as: :sidebar_json)["private"]
    assert_equal false, @open.as_json(as: :sidebar_json)["private"]
  end

end
