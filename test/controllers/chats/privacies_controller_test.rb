require "test_helper"

# Making a conversation private after it started (eKmnrJ): who's in is who is
# there now. The person who does it, every human who has written in it and the
# residents seated keep it; everyone else loses it, and no resident can join.
class Chats::PrivaciesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @account = accounts(:team_account)
    @owner = @account.memberships.find_by!(role: "owner").user
    @member = @account.memberships.find_by!(role: "member").user
    @reader = users(:regular_user)
    @account.memberships.create!(user: @reader, role: "member", confirmed_at: Time.current)
    @inside = @account.agents.create!(name: "Inside", runtime: "external", model_id: "openrouter/auto", system_prompt: "x")
    @later = @account.agents.create!(name: "Later", runtime: "external", model_id: "openrouter/auto", system_prompt: "x")
    @chat = @account.chats.create_with_message!({ title: "Garden shed", manual_responses: true },
      user: @member, message_content: "quince jelly", agent_ids: [ @inside.id ], automatic_response: false)
    @chat.messages.create!(role: "user", user: @owner, content: "medlar", suppress_automatic_dispatch: true)
  end

  test "the people already in it keep it and nobody else does" do
    sign_in @reader
    get account_chat_path(@account, @chat), as: :json
    assert_response :success

    sign_in @member
    post account_chat_privacy_path(@account, @chat)
    assert_response :redirect
    assert @chat.reload.private?
    assert_equal({ @member.id => "made_private", @owner.id => "writer" },
      @chat.chat_participants.pluck(:user_id, :source).to_h)

    [ @member, @owner ].each do |user|
      sign_in user
      get account_chat_path(@account, @chat), as: :json
      assert_response :success, "#{user.id} should keep it"
    end

    sign_in @reader
    get account_chat_path(@account, @chat), as: :json
    assert_response :not_found
    get account_chats_path(@account)
    refute_includes response.body, "Garden shed"
    get search_account_chats_path(@account), params: { q: "quince" }
    refute_includes response.body, "quince jelly"

    assert Chat.visible_to(@inside).exists?(@chat.id)
    refute @chat.chat_agents.build(agent: @later).valid?
  end

  test "someone who can't see it can't make it private" do
    @chat.make_private!(by: @member)
    sign_in @reader
    post account_chat_privacy_path(@account, @chat)
    assert_response :not_found
  end

  test "doing it twice changes nothing" do
    assert @chat.make_private!(by: @member)
    refute @chat.make_private!(by: @owner)
    assert_equal "made_private", @chat.chat_participants.find_by!(user: @member).source
  end

  test "a published stone has to be withdrawn first" do
    stone = @chat.stones.create!
    sign_in @member
    post account_chat_privacy_path(@account, @chat)
    assert_equal "Withdraw this conversation's published stones first", flash[:alert]
    refute @chat.reload.private?

    stone.update_columns(withdrawn_at: Time.current)
    post account_chat_privacy_path(@account, @chat)
    assert @chat.reload.private?
  end

  # A publication carrying a stale, ordinary copy of the conversation across
  # the conversion (#1092, Mira): it rechecks under the shared lock and fails.
  test "a publication holding a stale ordinary copy can't land after the lock" do
    stale = Chat.find(@chat.id)
    @chat.make_private!(by: @member)
    refute stale.private?

    assert_raises(Stone::InvalidInput) do
      Stone.publish!(chat: stale, title: "Leak", html: "<p>quince</p>", author: @member, public: true)
    end
    assert_equal 0, Stone.where(chat_id: @chat.id).count
  end

end
