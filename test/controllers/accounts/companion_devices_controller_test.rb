require "test_helper"

class Accounts::CompanionDevicesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @agent = agents(:research_assistant)
    @account = @agent.account
    @owner = users(:user_1)
    grant = CompanionEnrollmentGrant.create!(account: @account, minting_agent: @agent,
      created_by_user: @owner, name: "Daniel's Mac", device_request_id: "fixture",
      policy: { "residents" => [ { "id" => @agent.obfuscated_id,
        "volumes" => [ { "volume" => "Data", "access" => "read" } ], "execute" => false } ] },
      expires_at: 1.hour.from_now)
    @device, = CompanionEnrollmentGrant.enroll!(grant.issue_token!(@agent), "fixture")
    @device.update!(connection_epoch: "epoch")
  end

  def inertia
    { "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest }
  end

  def path
    account_companion_device_path(@account, @device)
  end

  test "an owner sees each computer, its residents, their folders and the warnings" do
    sign_in @owner
    get account_companion_devices_path(@account), headers: inertia
    assert_response :success
    props = inertia_shared_props
    assert_equal true, props.fetch("can_manage")
    device = props.fetch("devices").sole
    assert_equal [ "Daniel's Mac", true, false ], device.values_at("name", "connected", "paused")
    resident = device.fetch("residents").sole
    assert_equal [ "Research Assistant", false, false ], resident.values_at("name", "execute", "desktop")
    assert_equal [ { "volume" => "Data", "access" => "read" } ], resident.fetch("volumes")
    assert_equal CompanionEnrollmentGrant::DESKTOP_WARNING, props.dig("warnings", "desktop")
    assert_not_includes response.body, @device.credential_digest
  end

  test "an owner turns desktop on and off, with an audit row and a new revision each time" do
    sign_in @owner
    assert_difference -> { AuditLog.where(action: "companion.device.authority_changed").count }, 2 do
      patch path, params: { control: "authority", resident_id: @agent.obfuscated_id, execute: "false", desktop: "true" }
      assert_redirected_to account_companion_devices_path(@account)
      assert_equal true, @device.reload.policy.dig("residents", 0, "desktop")
      assert_equal 2, @device.grant_revision

      patch path, params: { control: "authority", resident_id: @agent.obfuscated_id, execute: "false", desktop: "false" }
    end
    assert_not @device.reload.policy.dig("residents", 0).key?("desktop")
    assert_equal 3, @device.grant_revision
    assert_equal @owner, AuditLog.where(action: "companion.device.authority_changed").last.user
  end

  test "a member who is not an admin sees the page read-only and cannot change anything" do
    agent = agents(:other_account_agent)
    team = agent.account
    grant = CompanionEnrollmentGrant.create!(account: team, minting_agent: agent, created_by_user: @owner,
      name: "Team Mac", device_request_id: "team", expires_at: 1.hour.from_now,
      policy: { "residents" => [ { "id" => agent.obfuscated_id, "volumes" => [], "execute" => false } ] })
    device, = CompanionEnrollmentGrant.enroll!(grant.issue_token!(agent), "team")
    sign_in users(:existing_user) # team_member: confirmed, role member
    get account_companion_devices_path(team), headers: inertia
    assert_response :success
    assert_equal false, inertia_shared_props.fetch("can_manage")
    assert_equal [ "Team Mac" ], inertia_shared_props.fetch("devices").map { |d| d.fetch("name") }

    team_path = account_companion_device_path(team, device)
    patch team_path, params: { control: "authority", resident_id: agent.obfuscated_id, execute: "true", desktop: "true" }
    assert_redirected_to account_companion_devices_path(team)
    patch team_path, params: { control: "revoke" }
    device.reload
    assert_equal false, device.policy.dig("residents", 0, "execute")
    assert_nil device.revoked_at
    assert_equal 1, device.grant_revision
  end

  test "someone outside the account cannot see or change its computers" do
    sign_in users(:existing_user)
    get account_companion_devices_path(@account), headers: inertia
    assert_not_equal 200, response.status
    patch path, params: { control: "revoke" }
    assert_nil @device.reload.revoked_at
  end

  test "pause cancels active work and resume lifts it; remove revokes and hides the computer" do
    sign_in @owner
    operation = CompanionOperation.start!(device: @device, agent: @agent, kind: "stat",
      arguments: { "volume" => "Data", "path" => "fixture" })
    patch path, params: { control: "pause" }
    assert @device.reload.paused
    assert_equal [ "cancelled", "changed" ], operation.reload.values_at(:state, :outcome)
    assert AuditLog.exists?(action: "companion_pause", auditable: @device, account: @account)

    patch path, params: { control: "resume" }
    assert_not @device.reload.paused

    patch path, params: { control: "revoke" }
    assert @device.reload.revoked_at
    get account_companion_devices_path(@account), headers: inertia
    assert_empty inertia_shared_props.fetch("devices")
    patch path, params: { control: "resume" }
    assert_response :not_found
  end

  test "an unknown control or a resident not on the computer changes nothing" do
    sign_in @owner
    patch path, params: { control: "explode" }
    patch path, params: { control: "authority", resident_id: agents(:research_assistant).obfuscated_id.reverse,
      execute: "true", desktop: "true" }
    patch path, params: { control: "authority", resident_id: @agent.obfuscated_id, execute: "yes", desktop: "true" }
    @device.reload
    assert_equal 1, @device.grant_revision
    assert_not @device.paused
  end

end
