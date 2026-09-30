require "test_helper"

class Chats::DraftsControllerTest < ActionDispatch::IntegrationTest

  setup do
    Setting.instance.update!(allow_chats: true)
    @user = users(:user_1)
    @account = accounts(:team_account)
    @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Draft test")
    post login_path, params: { email_address: @user.email_address, password: "password123" }
    @path = account_chat_draft_path(@account, @chat)
  end

  test "private empty draft, autosave and fresh client read" do
    get @path, as: :json
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal({ "content" => "", "revision" => 0 }, response.parsed_body["draft"])

    assert_no_difference [ "Message.count", "AuditLog.count", "AgentRuntimeInteraction.count" ] do
      patch @path, params: { content: "Careful\ncomments", revision: 0 }, as: :json
    end
    assert_response :success
    assert_equal 1, response.parsed_body.dig("draft", "revision")
    other = open_session
    other.post login_path, params: { email_address: @user.email_address, password: "password123" }
    other.get @path, as: :json
    assert_equal "Careful\ncomments", other.response.parsed_body.dig("draft", "content")
  end

  test "stale or absent revisions cannot overwrite or resurrect a cleared draft" do
    patch @path, params: { content: "first", revision: 0 }, as: :json
    patch @path, params: { content: "", revision: 1 }, as: :json
    assert_response :success
    [ 0, 1, nil, "garbage", "2junk" ].each do |revision|
      patch @path, params: { content: "stale", revision: revision }, as: :json
      assert_response :conflict
      assert_equal({ "content" => "", "revision" => 2 }, response.parsed_body["draft"])
    end
  end

  test "missing null structured and oversized text do not erase a draft" do
    patch @path, params: { content: "keep", revision: 0 }, as: :json
    [ nil, { bad: "text" }, [ "text" ], "x" * 100_001 ].each do |content|
      patch @path, params: { content: content, revision: 1 }, as: :json
      assert_response :unprocessable_entity
    end
    assert_equal "keep", ConversationDraft.last.content
  end

  test "other account denied and another member sees only their own draft" do
    patch @path, params: { content: "private", revision: 0 }, as: :json
    other = users(:existing_user)
    assert @account.memberships.find_by!(user: other).confirmed?
    post login_path, params: { email_address: other.email_address, password: "password123" }
    get @path, params: { user_id: @user.id }, as: :json
    assert_response :success
    assert_equal "", response.parsed_body.dig("draft", "content")
    @account.memberships.find_by!(user: other).destroy!
    get @path, as: :json
    assert_response :not_found
    assert_equal "private", ConversationDraft.find_by!(user: @user).content
  end

  test "successful send consumes matching draft atomically and rejects late saves" do
    patch @path, params: { content: "send me", revision: 0 }, as: :json
    assert_difference "Message.count", 1 do
      post account_chat_messages_path(@account, @chat),
        params: { message: { content: "send me" }, draft_revision: 1 }, as: :json
    end
    assert_response :created
    assert_equal({ "content" => "", "revision" => 2 }, response.parsed_body["draft"])
    patch @path, params: { content: "late autosave", revision: 1 }, as: :json
    assert_response :conflict
  end

  test "a tab belonging to a previous login cannot save or send as the replacement user" do
    headers = { "X-Draft-User" => users(:existing_user).to_param }
    patch @path, params: { content: "previous user's text", revision: 0 }, headers: headers, as: :json
    assert_response :forbidden
    assert_no_difference "Message.count" do
      post account_chat_messages_path(@account, @chat),
        params: { message: { content: "previous user's text" }, draft_revision: 0 }, headers: headers, as: :json
    end
    assert_response :forbidden
    assert_equal 0, ConversationDraft.count
  end

  test "site admin browsing does not widen private draft access" do
    admin = users(:site_admin_user)
    post login_path, params: { email_address: admin.email_address, password: "password123" }
    get @path, as: :json
    assert_response :not_found
    assert_equal 0, ConversationDraft.count
  end

  test "disabled accounts and unconfirmed membership cannot retrieve drafts" do
    patch @path, params: { content: "private", revision: 0 }, as: :json
    @account.update!(disabled_at: Time.current)
    get @path, as: :json
    assert_response :not_found
    @account.update!(disabled_at: nil)
    @account.memberships.find_by!(user: @user).update!(confirmed_at: nil)
    get @path, as: :json
    assert_response :not_found
    assert_equal "private", ConversationDraft.last.content
  end

  test "failed and conflicting sends retain draft and do not post" do
    patch @path, params: { content: "keep", revision: 0 }, as: :json
    assert_no_difference "Message.count" do
      post account_chat_messages_path(@account, @chat),
        params: { message: { content: "keep" }, draft_revision: 0 }, as: :json
    end
    assert_response :conflict
    assert_equal "keep", ConversationDraft.last.content
    assert_no_difference "Message.count" do
      post account_chat_messages_path(@account, @chat),
        params: { message: { content: "different" }, draft_revision: 1 }, as: :json
    end
    assert_response :conflict
    patch @path, params: { content: "", revision: 1 }, as: :json
    post account_chat_messages_path(@account, @chat),
      params: { message: { content: "" }, draft_revision: 2 }, as: :json
    assert_response :unprocessable_entity
    assert_equal 2, ConversationDraft.last.revision
  end

end
