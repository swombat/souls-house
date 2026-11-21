require "test_helper"
require "support/api_human_key_helpers"

# Private conversations (eKmnrJ), from outside: the account's admin who
# isn't in it and a resident without a seat get neither content nor metadata,
# and the creator gets it all, before posting.
class PrivateChatVisibilityTest < ActionDispatch::IntegrationTest

  include ApiHumanKeyHelpers

  setup do
    @account = accounts(:team_account)
    @admin = @account.memberships.find_by!(role: "owner").user
    @creator = @account.memberships.find_by!(role: "member").user
    @inside = @account.agents.create!(name: "Inside", runtime: "external", model_id: "openrouter/auto", system_prompt: "x")
    @outside = @account.agents.create!(name: "Outside", runtime: "external", model_id: "openrouter/auto", system_prompt: "x")
    @chat = @account.chats.create_with_message!({ title: "Secret garden", private: true, manual_responses: true },
      user: @creator, agent_ids: [ @inside.id ], automatic_response: false)
    @message = @chat.messages.create!(role: "user", user: @creator, content: "quince jelly", suppress_automatic_dispatch: true)
  end

  test "an admin outside it gets 404s, no row, no count and no search hit" do
    sign_in @admin
    [ account_chat_path(@account, @chat), account_chat_messages_path(@account, @chat) ].each do |path|
      get path, as: :json
      assert_response :not_found
      refute_includes response.body, "quince jelly"
    end
    patch message_path(@message), params: { message: { content: "changed" } }, as: :json
    assert_response :not_found
    post account_chat_fork_path(@account, @chat)
    assert_response :not_found

    get account_chats_path(@account)
    refute_includes response.body, "Secret garden"
    get search_account_chats_path(@account), params: { q: "quince" }
    refute_includes response.body, "quince jelly"
    refute_includes response.body, "Secret garden"
  end

  test "the creator sees it, with the lock, before and after posting" do
    sign_in @creator
    get account_chat_path(@account, @chat)
    assert_response :success
    assert_includes response.body, "Secret garden"
    get search_account_chats_path(@account), params: { q: "quince" }
    assert_includes response.body, "quince jelly"
  end

  test "the APIs: an unseated resident and an outside human get 404; a seated resident reads" do
    [ resident_headers(@admin, @outside), human_headers(@admin, @account) ].each do |headers|
      get api_v1_conversation_path(@chat), headers: headers
      assert_response :not_found
      refute_includes response.body, "quince jelly"
      get api_v1_conversations_path, headers: headers
      refute_includes response.body, "Secret garden"
    end

    get api_v1_conversation_path(@chat), headers: resident_headers(@admin, @inside)
    assert_response :success
    assert_includes response.body, "quince jelly"
  end

  test "nobody can be seated after it starts" do
    post api_v1_conversation_participants_path(@chat), params: { agent_id: @outside.to_param },
      headers: resident_headers(@admin, @inside)
    assert_response :unprocessable_entity
    refute @chat.reload.agents.include?(@outside)
    assert_raises(ActiveRecord::RecordInvalid) { @chat.chat_agents.create!(agent: @outside) }
  end

  test "a new private chat from the web form records its creator" do
    sign_in @creator
    assert_difference -> { @account.chats.where(private: true).count } do
      post account_chats_path(@account), params: { chat: { title: "Mine", private: "true" }, message: "hi",
        agent_ids: [ @inside.to_param ] }
    end
    chat = @account.chats.where(private: true).order(:id).last
    assert chat.visible_to?(@creator)
    refute chat.visible_to?(@admin)
  end

end
