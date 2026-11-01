require "test_helper"

# The two pages of a guest integration grant (JWblqj): the sharing house's
# Integrations page, where a guest is switched on, and the home's resident
# Integrations tab, where an owner approves, declines or revokes.
class Agents::GuestAccessApprovalsControllerTest < ActionDispatch::IntegrationTest

  setup do
    Setting.instance.update!(allow_agents: true)
    @daniel = users(:user_1)
    @anna = users(:existing_user)
    @home = accounts(:personal_account)
    @sharing = accounts(:team_account)
    @lume = agents(:research_assistant)
    @sharing.guest_memberships.create!(agent: @lume, added_by: @daniel)
    @connection = @sharing.service_connections.create!(
      connected_by_user: @anna,
      provider: "google_workspace",
      external_subject_id: "google-anna",
      external_identity: "anna@example.test",
      management_scope: "personal",
      credential_kind: "oauth2",
      credential_payload_hash: { "access_token" => "anna-access", "refresh_token" => "r", "expires_at" => 2.days.from_now.utc.iso8601 },
      credential_metadata: { "credential_strategy" => "refresh_broker", "granted_scopes" => [ "https://www.googleapis.com/auth/drive.readonly" ] }
    )
  end

  test "the sharing house's owner switches a guest on and the home is asked" do
    sign_in @anna

    patch account_agent_service_access_path(@sharing, @lume, @connection.public_id), params: { enabled: true },
          headers: { "HTTP_REFERER" => account_integrations_path(@sharing) }

    assert_redirected_to account_integrations_path(@sharing)
    assert_match(/asked to approve/, flash[:notice])
    access = @lume.agent_service_accesses.find_by!(service_connection: @connection)
    assert_equal "pending", access.home_approval
    assert_equal "share_service_with_guest", AuditLog.last.action
  end

  test "an account owner who does not own the personal connection cannot share it with a guest" do
    @connection.update!(freely_provisionable: true)
    sign_in @daniel

    patch account_agent_service_access_path(@sharing, @lume, @connection.public_id), params: { enabled: true },
          headers: { "HTTP_REFERER" => account_integrations_path(@sharing) }

    assert_redirected_to account_integrations_path(@sharing)
    assert_match(/owner/, flash[:alert])
    assert_nil @lume.agent_service_accesses.find_by(service_connection: @connection)
  end

  test "the sharing page lists the guest with its home and where the request stands" do
    @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    sign_in @anna

    get account_integrations_path(@sharing)

    assert_response :success
    connection = inertia_shared_props["connections"].find { |c| c["id"] == @connection.public_id }
    guest = connection["residents"].find { |r| r["id"] == @lume.to_param }
    assert guest["guest"]
    assert_equal @home.name, guest["home_account_name"]
    assert_equal "pending", guest["home_approval"]
    assert guest["enabled"]
    assert_not guest["effective"]
    assert guest["can_share"]
  end

  test "the home's owner sees the offer on the resident's Integrations tab and approves it" do
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    sign_in @daniel

    get edit_account_agent_path(@home, @lume, tab: "integrations")
    assert_response :success
    shared = inertia_shared_props["shared_connections"].sole
    assert_equal @connection.public_id, shared["id"]
    assert_equal @sharing.name, shared["shared_from"]
    assert_equal "pending", shared["home_approval"]
    assert_equal 1, shared["home_approval_generation"]
    assert inertia_shared_props["can_decide_guest_access"]

    patch account_agent_guest_access_approval_path(@home, @lume, @connection.public_id),
          params: { decision: "approve", generation: 1 }

    assert_redirected_to edit_account_agent_path(@home, @lume, tab: "integrations")
    assert_equal "approved", access.reload.home_approval
    assert access.effective?
    assert_equal "approve_guest_service_access", AuditLog.last.action
  end

  test "a stale approve button is refused" do
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    sign_in @daniel

    patch account_agent_guest_access_approval_path(@home, @lume, @connection.public_id),
          params: { decision: "approve", generation: 0 }

    assert_redirected_to edit_account_agent_path(@home, @lume, tab: "integrations")
    assert_match(/changed since you saw it/, flash[:alert])
    assert_equal "pending", access.reload.home_approval
  end

  test "only an owner of the home decides" do
    # A team home: the team account hosts a resident seated as a guest in
    # Another Team, whose connection is owned by existing_user. existing_user
    # is a member, not an owner, of the home.
    home = @sharing
    elsewhere = accounts(:another_team)
    local = home.agents.create!(name: "Local", model_id: "openrouter/auto")
    elsewhere.guest_memberships.create!(agent: local, added_by: @anna)
    connection = elsewhere.service_connections.create!(
      connected_by_user: @anna, provider: "oura", external_subject_id: "oura-elsewhere",
      management_scope: "personal", credential_kind: "oauth2",
      credential_payload_hash: { "access_token" => "t", "refresh_token" => "r", "expires_at" => 2.days.from_now.utc.iso8601 },
      credential_metadata: { "credential_strategy" => "refresh_broker" }
    )
    access = local.set_service_access!(connection, enabled: true, actor: @anna)
    sign_in @anna

    patch account_agent_guest_access_approval_path(home, local, connection.public_id),
          params: { decision: "approve", generation: 1 }

    assert_response :redirect
    assert_equal "pending", access.reload.home_approval

    sign_in @daniel # owner of the team account
    patch account_agent_guest_access_approval_path(home, local, connection.public_id),
          params: { decision: "approve", generation: 1 }
    assert_equal "approved", access.reload.home_approval
  end

  test "the home revokes an approval" do
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    access.approve_home!(actor: @daniel, generation: 1)
    sign_in @daniel

    patch account_agent_guest_access_approval_path(@home, @lume, @connection.public_id), params: { decision: "revoke" }

    assert_equal "revoked", access.reload.home_approval
    assert_not access.enabled?
  end

  test "a hosted row is not a guest grant" do
    local = @sharing.agents.create!(name: "Local", model_id: "openrouter/auto")
    local.set_service_access!(@connection, enabled: true, actor: @anna)
    sign_in @daniel

    patch account_agent_guest_access_approval_path(@sharing, local, @connection.public_id), params: { decision: "revoke" }

    assert_response :not_found
  end

end
