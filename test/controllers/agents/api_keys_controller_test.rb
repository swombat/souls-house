require "test_helper"

class Agents::ApiKeysControllerTest < ActionDispatch::IntegrationTest

  setup do
    @owner = users(:user_1)
    @account = accounts(:team_account)
    @agent = agents(:other_account_agent) # external, in team_account
    Setting.instance.update!(allow_agents: true)
    @outbound = ApiKey.generate_for(@owner, name: "agent:#{@agent.id}:outbound", agent: @agent)
    @agent.update!(outbound_api_key: @outbound, outbound_api_token: @outbound.raw_token)
  end

  test "an owner creates a named key for a resident; it is shown once and acts as the resident" do
    sign_in(@owner)

    assert_difference [ "ApiKey.count", "AuditLog.count" ], 1 do
      post account_agent_other_body_keys_path(@account, @agent), params: { name: "Desktop" }
    end

    assert_response :success
    assert_equal "api_keys/show", inertia_component
    assert_equal settings_path, inertia_shared_props.fetch("return_url")
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
      delete account_agent_other_body_key_path(@account, @agent, desktop)
    end

    assert_redirected_to settings_path
    assert_nil ApiKey.authenticate(desktop.raw_token)
    assert_equal @agent, ApiKey.authenticate(@outbound.raw_token).agent
    assert_equal @agent, ApiKey.authenticate(phone.raw_token).agent
    assert_equal "revoke_resident_api_key", AuditLog.order(:created_at).last.action
  end

  test "both resident keys are unauthorized while disabled and work again after re-enabling" do
    desktop = ApiKey.generate_for(@owner, name: "Desktop", agent: @agent, account: @account)
    chat = @account.chats.create!(title: "Resident conversation", manual_responses: true, agents: [ @agent ])

    [ true, false, true ].each do |enabled|
      @agent.update_columns(active: enabled)
      [ @outbound, desktop ].each do |key|
        get api_v1_conversation_url(chat), headers: { "Authorization" => "Bearer #{key.raw_token}" }
        assert_response(enabled ? :success : :unauthorized)
      end
    end
  end

  test "the outbound key cannot be revoked here" do
    sign_in(@owner)

    assert_no_difference "ApiKey.count" do
      delete account_agent_other_body_key_path(@account, @agent, @outbound)
    end
    assert_response :not_found
  end

  test "a member who is not an owner can neither create nor revoke" do
    desktop = ApiKey.generate_for(@owner, name: "Desktop", agent: @agent, account: @account)
    sign_in(users(:existing_user)) # a confirmed member of team_account, not an owner

    assert_no_difference "ApiKey.count" do
      post account_agent_other_body_keys_path(@account, @agent, format: :json), params: { name: "Mine" }
      assert_response :forbidden
      delete account_agent_other_body_key_path(@account, @agent, desktop, format: :json)
      assert_response :forbidden
    end
    assert ApiKey.authenticate(desktop.raw_token)
  end

  test "a resident of another account cannot be given a key here" do
    sign_in(@owner)
    stranger = agents(:research_assistant)

    assert_no_difference "ApiKey.count" do
      post account_agent_other_body_keys_path(@account, stranger), params: { name: "Desktop" }
    end
    assert_response :not_found
  end

  test "revocation is restricted to the displayed resident as well as the account" do
    sign_in(@owner)
    desktop = ApiKey.generate_for(@owner, name: "Desktop", agent: @agent, account: @account)
    peer = agents(:code_reviewer).tap { |agent| agent.update_columns(account_id: @account.id) }

    assert_no_difference "ApiKey.count" do
      delete account_agent_other_body_key_path(@account, peer, desktop)
    end
    assert_response :not_found
    assert desktop.reload.persisted?
  end

  test "settings show only this resident's named keys to the owner" do
    desktop = ApiKey.generate_for(@owner, name: "Desktop", agent: @agent, account: @account)
    peer = agents(:code_reviewer).tap { |agent| agent.update_columns(account_id: @account.id) }
    ApiKey.generate_for(@owner, name: "Phone", agent: peer, account: @account)
    sign_in(@owner)

    get settings_path

    assert_response :success
    props = inertia_shared_props.fetch("resident_api_keys")
    assert_equal account_agent_other_body_keys_path(@account, @agent), props.fetch("create_url")
    assert_equal [ desktop.id ], props.fetch("keys").pluck("id")
    assert_equal account_agent_other_body_key_path(@account, @agent, desktop), props.fetch("keys").first.fetch("revoke_url")
    assert_not_includes response.body, desktop.raw_token
  end

  test "settings omit management props for a non-owner member" do
    sign_in(users(:existing_user))

    get settings_path

    assert_response :success
    assert_nil inertia_shared_props.fetch("resident_api_keys")
  end

  test "an ineligible resident has no section and cannot receive keys" do
    @agent.update_columns(runtime: "deprecated")
    sign_in(@owner)

    get settings_path
    assert_response :success
    assert_nil inertia_shared_props.fetch("resident_api_keys")

    assert_no_difference "ApiKey.count" do
      post account_agent_other_body_keys_path(@account, @agent), params: { name: "Desktop" }
    end
    assert_response :not_found
  end

  private

  def settings_path
    edit_account_agent_path(@account, @agent, tab: "settings", anchor: "connect-another-body")
  end

end
