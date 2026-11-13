require "test_helper"

class ResidentApiKeysControllerTest < ActionDispatch::IntegrationTest

  setup do
    @owner = users(:user_1)
    @account = accounts(:team_account)
    @agent = agents(:other_account_agent) # external, in team_account
    @outbound = ApiKey.generate_for(@owner, name: "agent:#{@agent.id}:outbound", agent: @agent)
    @agent.update!(outbound_api_key: @outbound, outbound_api_token: @outbound.raw_token)
  end

  test "an owner creates a named key for a resident; it is shown once and acts as the resident" do
    sign_in(@owner)

    assert_difference [ "ApiKey.count", "AuditLog.count" ], 1 do
      post account_resident_api_keys_path(@account), params: { agent_id: @agent.to_param, name: "Desktop" }
    end

    assert_response :success
    assert_equal "api_keys/show", inertia_component
    raw = inertia_shared_props.fetch("raw_token")
    key = ApiKey.authenticate(raw)
    assert_equal @agent, key.agent
    assert_equal @account, key.account
    assert_equal "Desktop", key.name
    assert key.resident_named?
    assert_not @outbound.reload.resident_named?

    log = AuditLog.order(:created_at).last
    assert_equal "create_resident_api_key", log.action
    assert_equal @owner, log.user
    assert_equal key, log.auditable
  end

  test "the named key has the outbound key's scope: it reads the resident's conversations, not others" do
    key = ApiKey.generate_for(@owner, name: "Desktop", agent: @agent, account: @account)
    own = @account.chats.create!(title: "With the resident", manual_responses: true, agent_ids: [ @agent.id ])
    peer = agents(:code_reviewer).tap { |agent| agent.update_columns(account_id: @account.id) }
    other = @account.chats.create!(title: "Without the resident", manual_responses: true, agent_ids: [ peer.id ])

    get api_v1_conversation_url(own), headers: { "Authorization" => "Bearer #{key.raw_token}" }
    assert_response :success
    get api_v1_conversation_url(other), headers: { "Authorization" => "Bearer #{key.raw_token}" }
    assert_response :not_found
  end

  test "revoking one named key leaves the outbound key and other named keys working" do
    sign_in(@owner)
    desktop = ApiKey.generate_for(@owner, name: "Desktop", agent: @agent, account: @account)
    phone = ApiKey.generate_for(@owner, name: "Phone", agent: @agent, account: @account)

    assert_difference "ApiKey.count", -1 do
      delete account_resident_api_key_path(@account, desktop)
    end

    assert_redirected_to account_api_keys_path(@account)
    assert_nil ApiKey.authenticate(desktop.raw_token)
    assert_equal @agent, ApiKey.authenticate(@outbound.raw_token).agent
    assert_equal @agent, ApiKey.authenticate(phone.raw_token).agent
    assert_equal "revoke_resident_api_key", AuditLog.order(:created_at).last.action
  end

  test "the outbound key cannot be revoked here" do
    sign_in(@owner)

    assert_no_difference "ApiKey.count" do
      delete account_resident_api_key_path(@account, @outbound)
    end
    assert_response :not_found
  end

  test "a member who is not an owner can neither create nor revoke" do
    desktop = ApiKey.generate_for(@owner, name: "Desktop", agent: @agent, account: @account)
    sign_in(users(:existing_user)) # a confirmed member of team_account, not an owner

    assert_no_difference "ApiKey.count" do
      post account_resident_api_keys_path(@account), params: { agent_id: @agent.to_param, name: "Mine" }
      delete account_resident_api_key_path(@account, desktop)
    end
    assert ApiKey.authenticate(desktop.raw_token)
  end

  test "a resident of another account cannot be given a key here" do
    sign_in(@owner)
    stranger = agents(:research_assistant)

    assert_no_difference "ApiKey.count" do
      post account_resident_api_keys_path(@account), params: { agent_id: stranger.to_param, name: "Desktop" }
    end
    assert_response :not_found
  end

  test "the external access page lists named keys apart from the container keys" do
    sign_in(@owner)
    desktop = ApiKey.generate_for(@owner, name: "Desktop", agent: @agent, account: @account)

    get account_api_keys_path(@account)

    assert_equal [ desktop.id ], inertia_shared_props.fetch("resident_named_keys").map { |key| key.fetch("id") }
    assert_equal [ @outbound.id ], inertia_shared_props.fetch("chaos_agent_access_keys").map { |key| key.fetch("id") }
    assert inertia_shared_props.fetch("can_manage_resident_keys")
    assert_includes inertia_shared_props.fetch("key_residents").map { |r| r.fetch("id") }, @agent.to_param
  end

end
