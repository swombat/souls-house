require "test_helper"

# The ceiling report (what the computer says its own local ceiling allows) and
# the owner's per-folder change on top of it.
class CompanionDeviceVolumeTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @owner = users(:user_1)
    @id = @agent.obfuscated_id
    grant = CompanionEnrollmentGrant.create!(account: @agent.account, minting_agent: @agent,
      created_by_user: @owner, name: "Mac", device_request_id: "fixture", expires_at: 1.hour.from_now,
      policy: { "residents" => [ { "id" => @id, "execute" => true, "desktop" => true,
        "volumes" => [ { "volume" => "Data", "access" => "read" }, { "volume" => "Music", "access" => "write" } ] } ] })
    @device, = CompanionEnrollmentGrant.enroll!(grant.issue_token!(@agent), "fixture")
    @device.update!(connection_epoch: "epoch-1")
  end

  def ceiling(*volumes, id: @id)
    { "residents" => [ { "id" => id, "volumes" => volumes.map { |v, a| { "volume" => v, "access" => a } } } ] }
  end

  def report(value, epoch: "epoch-1", claimed: epoch)
    @device.record_ceiling_report!(epoch: epoch, claimed_epoch: claimed, ceiling: value)
  end

  def change(volume, access)
    @device.change_resident_volume!(resident_id: @id, volume: volume, access: access, actor: @owner)
  end

  def volumes
    @device.reload.policy.dig("residents", 0, "volumes").to_h { |v| [ v["volume"], v["access"] ] }
  end

  test "a report from the current connection is stored whole, replacing the last one" do
    assert report(ceiling([ "Data", "write" ], [ "Photos", "read" ]))
    assert report(ceiling([ "Data", "read" ]))
    @device.reload
    assert_equal ceiling([ "Data", "read" ]), @device.reported_ceiling
    assert_equal "epoch-1", @device.ceiling_epoch
    assert @device.ceiling_reported_at
  end

  test "a report from an old connection, or naming another epoch, is dropped" do
    assert report(ceiling([ "Data", "write" ]))
    @device.update!(connection_epoch: "epoch-2")
    assert_not report(ceiling([ "Photos", "write" ]), epoch: "epoch-1")
    assert_not report(ceiling([ "Photos", "write" ]), epoch: "epoch-2", claimed: "epoch-1")
    @device.update!(connection_epoch: nil)
    assert_not report(ceiling([ "Photos", "write" ]), epoch: nil, claimed: nil)
    assert_equal ceiling([ "Data", "write" ]), @device.reload.reported_ceiling
  end

  test "residents not enrolled on this device are not kept, and a malformed report is dropped whole" do
    outsider = agents(:other_account_agent).obfuscated_id
    value = { "residents" => ceiling([ "Data", "read" ])["residents"] + ceiling([ "Secret", "write" ], id: outsider)["residents"] }
    assert report(value)
    assert_equal ceiling([ "Data", "read" ]), @device.reload.reported_ceiling

    [ { "residents" => [ { "id" => @id, "volumes" => [ { "volume" => "Data", "access" => "admin" } ] } ] },
      { "residents" => [ { "id" => @id, "volumes" => [ { "volume" => "/Users/x", "access" => "read", "path" => "/" } ] } ] },
      { "residents" => [ { "id" => @id, "volumes" => [ { "volume" => "a" * 129, "access" => "read" } ] } ] },
      { "residents" => [ { "id" => @id, "volumes" => [], "execute" => true } ] },
      { "residents" => ceiling([ "A", "read" ])["residents"] * 2 },
      { "residents" => [], "extra" => 1 }, "residents", nil ].each do |bad|
      assert_not report(bad), "stored #{bad.inspect}"
    end
    assert_equal ceiling([ "Data", "read" ]), @device.reload.reported_ceiling
  end

  test "an empty ceiling is a report, not the absence of one, and a report never changes grants" do
    assert_nil @device.ceiling_access(@id, "Data")
    assert report({ "residents" => [ { "id" => @id, "volumes" => [] } ] })
    assert_equal "off", @device.reload.ceiling_access(@id, "Data")
    assert_equal({ "Data" => "read", "Music" => "write" }, volumes)
    assert_equal 1, @device.grant_revision
  end

  test "widening stays within the report, including off to write; without a report it is refused" do
    assert_raises(CompanionDevice::AboveCeiling) { change("Photos", "read") }
    report(ceiling([ "Data", "write" ], [ "Photos", "write" ], [ "Docs", "read" ]))
    assert change("Data", "write")
    assert change("Photos", "write")
    assert_raises(CompanionDevice::AboveCeiling) { change("Docs", "write") }
    assert_raises(CompanionDevice::AboveCeiling) { change("Elsewhere", "read") }
    assert_equal({ "Data" => "write", "Music" => "write", "Photos" => "write" }, volumes)
    assert_equal 3, @device.grant_revision
  end

  test "narrowing is always allowed, even for a folder the report lowered or no longer has" do
    report(ceiling([ "Data", "read" ]))
    assert change("Music", "read")
    assert change("Music", "off")
    assert_raises(CompanionDevice::AboveCeiling) { change("Music", "read") }
    assert change("Data", "off")
    assert_equal({}, volumes)
  end

  test "a change keeps every other folder and both switches, so stale pages editing different folders don't collide" do
    report(ceiling([ "Data", "write" ], [ "Music", "write" ], [ "Photos", "read" ]))
    stale_a = CompanionDevice.find(@device.id)
    stale_b = CompanionDevice.find(@device.id)
    assert stale_a.change_resident_volume!(resident_id: @id, volume: "Data", access: "write", actor: @owner)
    assert stale_b.change_resident_volume!(resident_id: @id, volume: "Photos", access: "read", actor: @owner)
    assert_equal({ "Data" => "write", "Music" => "write", "Photos" => "read" }, volumes)
    resident = @device.policy.dig("residents", 0)
    assert_equal [ true, true ], resident.values_at("execute", "desktop")
  end

  test "a change bumps the revision, cancels active work and writes an audit row; no change does nothing" do
    report(ceiling([ "Data", "write" ]))
    operation = CompanionOperation.start!(device: @device, agent: @agent, kind: "stat",
      arguments: { "volume" => "Data", "path" => "fixture" })
    assert_difference -> { AuditLog.where(action: "companion.device.volume_changed").count }, 1 do
      assert change("Data", "write")
      assert_not change("Data", "write")
    end
    assert_equal [ "cancelled", "changed" ], operation.reload.values_at(:state, :outcome)
    audit = AuditLog.where(action: "companion.device.volume_changed").last
    assert_equal [ "Data", "read", "write", @owner ], [ audit.data["volume"], audit.data["before"], audit.data["after"], audit.user ]
    assert_equal 2, @device.reload.grant_revision
  end

  test "bad input changes nothing" do
    report(ceiling([ "Data", "write" ]))
    assert_raises(ArgumentError) { change("Data", "admin") }
    assert_raises(ArgumentError) { change("", "read") }
    assert_raises(ArgumentError) { @device.change_resident_volume!(resident_id: "nobody", volume: "Data", access: "off", actor: @owner) }
    assert_equal 1, @device.reload.grant_revision
  end

end
