require "test_helper"

class Api::V1::DraftsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:confirmed_user)
    @account = @user.personal_account
    @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Private draft")
    @key = ApiKey.generate_for(@user, name: "Draft client")
    @headers = { "Authorization" => "Bearer #{@key.raw_token}" }
    @path = api_v1_conversation_draft_path(@chat)
  end

  test "human API and web share draft and API send consumes matching revision" do
    patch @path, params: { content: "from phone", revision: 0 }, headers: @headers, as: :json
    assert_response :success
    post login_path, params: { email_address: @user.email_address, password: "password123" }
    get account_chat_draft_path(@account, @chat), as: :json
    assert_response :success
    assert_equal "from phone", response.parsed_body.dig("draft", "content")
    post api_v1_conversation_messages_path(@chat),
      params: { content: "from phone", draft_revision: 1 }, headers: @headers, as: :json
    assert_response :created
    assert_equal({ "content" => "", "revision" => 2 }, response.parsed_body["draft"])
    patch @path, params: { content: "stale", revision: 1 }, headers: @headers, as: :json
    assert_response :conflict
  end

  test "agent credentials never read the key owner's private draft" do
    agent = agents(:research_assistant)
    @chat.agents << agent
    key = ApiKey.generate_for(@user, name: "Resident", agent: agent)
    get @path, headers: { "Authorization" => "Bearer #{key.raw_token}" }
    assert_response :forbidden
    patch @path, params: { content: "no", revision: 0 },
      headers: { "Authorization" => "Bearer #{key.raw_token}" }, as: :json
    assert_response :forbidden
    assert_equal 0, ConversationDraft.count
  end

  test "unauthenticated and foreign conversation requests fail" do
    get @path
    assert_response :unauthorized
    foreign = accounts(:team_account).chats.create!(model_id: "openrouter/auto", title: "Foreign")
    get api_v1_conversation_draft_path(foreign), headers: @headers
    assert_response :not_found
  end

end
