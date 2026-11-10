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

  test "each computer carries a week of job counts, its failures and the last job, but never what a job was" do
    op = ->(state, at) {
      CompanionOperation.create!(companion_device: @device, agent: @agent, kind: "list",
        arguments: { "path" => "secret-folder" }, state: state, connection_epoch: "epoch",
        grant_revision: @device.grant_revision, deadline: at + 1.minute, created_at: at)
    }
    op.call("completed", 2.hours.ago)
    op.call("failed", 2.hours.ago)
    op.call("completed", 3.days.ago)
    op.call("completed", 20.days.ago)

    sign_in @owner
    get account_companion_devices_path(@account), headers: inertia
    activity = inertia_shared_props.fetch("devices").sole.fetch("activity")
    assert_equal 7, activity.fetch("days").size
    assert_equal Time.current.utc.to_date.iso8601, activity.fetch("days").last.fetch("date")
    assert_equal 3, activity.fetch("days").sum { |day| day.fetch("jobs") }
    assert_equal 1, activity.fetch("failed")
    assert_in_delta 2.hours.ago, Time.zone.parse(activity.fetch("last_job_at")), 5
    assert_not_includes response.body, "secret-folder"
  end

  test "an owner turns desktop on and off, with an audit row and a new revision each time" do
    sign_in @owner
    assert_difference -> { AuditLog.where(action: "companion.device.authority_changed").count }, 2 do
      patch path, params: { control: "authority", resident_id: @agent.obfuscated_id, permission: "desktop", value: "true" }
      assert_redirected_to account_companion_devices_path(@account)
      assert_equal true, @device.reload.policy.dig("residents", 0, "desktop")
      assert_equal 2, @device.grant_revision

      patch path, params: { control: "authority", resident_id: @agent.obfuscated_id, permission: "desktop", value: "false" }
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
    patch team_path, params: { control: "authority", resident_id: agent.obfuscated_id, permission: "execute", value: "true" }
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
      permission: "execute", value: "true" }
    patch path, params: { control: "authority", resident_id: @agent.obfuscated_id, permission: "execute", value: "yes" }
    patch path, params: { control: "authority", resident_id: @agent.obfuscated_id, permission: "volumes", value: "true" }
    # The old two-flag shape is not accepted here: it would carry a stale copy of the other switch.
    patch path, params: { control: "authority", resident_id: @agent.obfuscated_id, execute: "true", desktop: "true" }
    @device.reload
    assert_equal 1, @device.grant_revision
    assert_not @device.paused
  end

  test "a stale page switching one power off cannot put back the other one" do
    sign_in @owner
    # Both on, as a page loaded now would show them.
    patch path, params: { control: "authority", resident_id: @agent.obfuscated_id, permission: "execute", value: "true" }
    patch path, params: { control: "authority", resident_id: @agent.obfuscated_id, permission: "desktop", value: "true" }
    assert_equal [ true, true ], @device.reload.policy.dig("residents", 0).values_at("execute", "desktop")

    # Another tab turns desktop off.
    patch path, params: { control: "authority", resident_id: @agent.obfuscated_id, permission: "desktop", value: "false" }
    # The first page, still showing desktop on, turns run-commands off.
    patch path, params: { control: "authority", resident_id: @agent.obfuscated_id, permission: "execute", value: "false" }

    resident = @device.reload.policy.dig("residents", 0)
    assert_equal false, resident["execute"]
    assert_not resident.key?("desktop"), "desktop came back without its confirmation"
    last = AuditLog.where(action: "companion.device.authority_changed").last
    assert_equal({ "execute" => false, "desktop" => false }, last.data["after"])
  end

end
