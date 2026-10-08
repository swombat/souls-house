require "test_helper"
require "support/app_oauth_test_helper"

# One API, several ways to authenticate: /api/v1 accepts a native-app OAuth
# access token as well as an API key. The token belongs to a person; it reaches
# every account they currently belong to, or the one account_id names.
class Api::V1::AppTokenAuthenticationTest < ActionDispatch::IntegrationTest

  include AppOauthTestHelper

  setup do
    @user = users(:existing_user)
    @personal = accounts(:existing_user_account)
    @team = accounts(:team_account)
    @client = create_app_client
    @tokens = sign_in_device
    @personal_chat = @personal.chats.create!(model_id: "openrouter/auto", title: "Personal room")
    @team_chat = @team.chats.create!(model_id: "openrouter/auto", title: "Team room")
    @foreign_chat = accounts(:regular_user_account).chats.create!(model_id: "openrouter/auto", title: "Not mine")
  end

  test "an OAuth token lists conversations across every account the person belongs to" do
    get api_v1_conversations_url, headers: bearer(@tokens)
    assert_response :success
    ids = response.parsed_body["conversations"].map { |c| c["id"] }
    assert_includes ids, @personal_chat.to_param
    assert_includes ids, @team_chat.to_param
    refute_includes ids, @foreign_chat.to_param
  end

  test "account_id narrows an OAuth token to one of the person's accounts" do
    get api_v1_conversations_url(account_id: @team.to_param), headers: bearer(@tokens)
    assert_response :success
    ids = response.parsed_body["conversations"].map { |c| c["id"] }
    assert_equal [ @team_chat.to_param ], ids & [ @team_chat.to_param, @personal_chat.to_param ]
  end

  test "an account the person does not belong to is 404, and so is a malformed id" do
    get api_v1_conversations_url(account_id: accounts(:regular_user_account).to_param), headers: bearer(@tokens)
    assert_response :not_found
    get api_v1_conversations_url(account_id: "not-an-id!"), headers: bearer(@tokens)
    assert_response :not_found
  end

  test "a conversation in another of the person's accounts can be read and posted to" do
    get api_v1_conversation_url(@team_chat), headers: bearer(@tokens)
    assert_response :success

    assert_difference -> { @team_chat.messages.count }, 1 do
      post api_v1_conversation_messages_url(@team_chat), params: { content: "From my agent" }, headers: bearer(@tokens)
    end
    assert_response :created
    message = @team_chat.messages.order(:id).last
    assert_equal @user, message.user
    assert_equal "user", message.role
  end

  test "a conversation outside the person's accounts is 404" do
    get api_v1_conversation_url(@foreign_chat), headers: bearer(@tokens)
    assert_response :not_found
    post api_v1_conversation_messages_url(@foreign_chat), params: { content: "nope" }, headers: bearer(@tokens)
    assert_response :not_found
  end

  test "membership is re-checked on every request" do
    get api_v1_conversation_url(@team_chat), headers: bearer(@tokens)
    assert_response :success

    memberships(:team_member).destroy!
    get api_v1_conversation_url(@team_chat), headers: bearer(@tokens)
    assert_response :not_found
  end

  test "a revoked device session is refused" do
    row_for(@tokens).app_session.revoke!(:user_revoked)
    get api_v1_conversations_url, headers: bearer(@tokens)
    assert_response :unauthorized
  end

  test "drafts work with an OAuth token in a non-default account" do
    get api_v1_conversation_draft_url(@team_chat), headers: bearer(@tokens)
    assert_response :success
  end

  test "an OAuth token is a person, never a resident" do
    get api_v1_house_inference_models_url, headers: bearer(@tokens)
    assert_response :forbidden
    get api_v1_memory_vault_url, headers: bearer(@tokens)
    assert_response :forbidden
  end

  test "site-admin endpoints still require a site-admin API key, not an OAuth token" do
    @user.update!(is_site_admin: true)
    get api_v1_admin_summary_url, headers: bearer(@tokens)
    assert_response :forbidden
  end

  test "API keys keep working exactly as before" do
    key = ApiKey.generate_for(@user, name: "Agent", account: @personal)
    get api_v1_conversations_url, headers: { "Authorization" => "Bearer #{key.raw_token}" }
    assert_response :success
    ids = response.parsed_body["conversations"].map { |c| c["id"] }
    assert_includes ids, @personal_chat.to_param
    refute_includes ids, @team_chat.to_param
  end


  test "a disabled default account does not block the person's other accounts" do
    # User#default_account falls back to the first confirmed membership without
    # checking that its account is enabled. Build a person whose first account is disabled.
    person = User.create!(email_address: "two-accounts@example.com", password: "password123")
    disabled = Account.create!(name: "Closed team", account_type: :team)
    Membership.create!(account: disabled, user: person, role: "owner", confirmed_at: 2.days.ago, created_at: 2.days.ago)
    Membership.create!(account: @team, user: person, role: "member", confirmed_at: 1.day.ago, created_at: 1.day.ago)
    closed_chat = disabled.chats.create!(model_id: "openrouter/auto", title: "Closed room")
    delete "/logout"
    @user = person
    tokens = sign_in_device
    disabled.update_columns(disabled_at: Time.current)
    assert_equal disabled, person.reload.default_account, "precondition: the fallback lands on the disabled account"

    get api_v1_conversations_url, headers: bearer(tokens)
    assert_response :success
    ids = response.parsed_body["conversations"].map { |c| c["id"] }
    assert_includes ids, @team_chat.to_param
    refute_includes ids, closed_chat.to_param

    get api_v1_conversation_url(@team_chat), headers: bearer(tokens)
    assert_response :success

    get api_v1_whiteboards_url, headers: bearer(tokens)
    assert_response :success, "an account-scoped action falls back to an enabled account"

    get api_v1_conversations_url(account_id: disabled.to_param), headers: bearer(tokens)
    assert_response :not_found
  end

  test "an array or object account_id is refused, for OAuth tokens and API keys alike" do
    get api_v1_conversations_url, params: { account_id: [ @team.to_param ] }, headers: bearer(@tokens)
    assert_response :unprocessable_entity
    get api_v1_conversations_url, params: { account_id: { id: @team.to_param } }, headers: bearer(@tokens)
    assert_response :unprocessable_entity

    key = ApiKey.generate_for(@user, name: "Agent", account: @personal)
    get api_v1_conversations_url, params: { account_id: [ @personal.to_param ] }, headers: { "Authorization" => "Bearer #{key.raw_token}" }
    assert_response :unprocessable_entity
  end

  test "through /api/v1 a rejected superseded bearer leaves its parent retryable" do
    t1 = @tokens
    t2 = refresh(t1)
    _lost = refresh(t1)
    get api_v1_conversations_url, headers: bearer(t2)
    assert_response :unauthorized
    assert_not row_for(t1).reload.revoked?
  end

  test "through /api/v1 an expired bearer cannot retire its parent" do
    t1 = @tokens
    t2 = refresh(t1)
    travel 16.minutes do
      get api_v1_conversations_url, headers: bearer(t2)
      assert_response :unauthorized
    end
    assert_not row_for(t1).reload.revoked?
  end

  test "through /api/v1 the first successful use of a refreshed bearer retires its parent" do
    t1 = @tokens
    t2 = refresh(t1)
    get api_v1_conversations_url, headers: bearer(t2)
    assert_response :success
    assert row_for(t1).reload.revoked?
  end

end
