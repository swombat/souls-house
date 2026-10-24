require "test_helper"

class CompanionDeviceTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    grant = CompanionEnrollmentGrant.create!(account: @account, minting_agent: @agent,
      created_by_user: users(:user_1), name: "Synthetic device", device_request_id: "device-request",
      policy: { "residents" => [ { "id" => @agent.obfuscated_id, "volumes" => [], "execute" => false } ] },
      expires_at: 1.hour.from_now)
    @device, @credential = CompanionEnrollmentGrant.enroll!(grant.issue_token!(@agent), "device-request")
  end

  test "rotates credential and encrypts exact response for retry without extra tickets" do
    result = CompanionDevice.create_session!(@credential, "session-1")
    assert_equal @device.to_param, result["device_id"]
    assert_equal 1, result["revision"]
    assert_equal @device.policy, result["policy"]
    assert_not_equal @credential, result["device_credential"]
    assert_nil CompanionDevice.authenticate(@credential)
    assert_equal @device, CompanionDevice.authenticate(result["device_credential"])
    assert_equal result, CompanionDevice.create_session!(@credential, "session-1")
    assert_equal result, CompanionDevice.create_session!(result["device_credential"], "session-1")
    assert_equal 1, @device.companion_cable_tickets.count
    @device.reload
    ciphertext = @device.ciphertext_for(:session_response)
    assert_not_includes ciphertext, result["device_credential"]
    assert_not_includes ciphertext, result["cable_ticket"]
    assert_equal result, JSON.parse(@device.session_response)
    assert_equal Digest::SHA256.hexdigest(result["cable_ticket"]), @device.companion_cable_tickets.sole.token_digest
  end

  test "public device and grant ids round trip through obfuscated lookup" do
    assert_equal @device, CompanionDevice.find(@device.obfuscated_id)
    grant = @device.companion_enrollment_grant
    assert_equal grant, CompanionEnrollmentGrant.find(grant.obfuscated_id)
    assert_not_equal @device.id.to_s, @device.obfuscated_id
  end

  test "ambiguous previous or overlapping current requests never revoke or rotate" do
    result = CompanionDevice.create_session!(@credential, "session-1")
    assert_raises(CompanionDevice::InvalidCredential) { CompanionDevice.create_session!(@credential, "session-2") }
    assert_raises(CompanionDevice::RetryConflict) { CompanionDevice.create_session!(result["device_credential"], "session-2") }
    assert_nil @device.reload.revoked_at
    assert_not AuditLog.where(action: "companion.device.stale_credential", auditable: @device).exists?
    assert_equal result, CompanionDevice.create_session!(@credential, "session-1")
    assert_equal @device, CompanionDevice.authenticate(result["device_credential"])
  end

  test "only current credential with fresh request can rotate after recovery window" do
    result = CompanionDevice.create_session!(@credential, "session-1")
    travel 61.seconds
    assert_difference -> { AuditLog.where(action: "companion.device.stale_credential", auditable: @device).count }, 1 do
      assert_raises(CompanionDevice::InvalidCredential) { CompanionDevice.create_session!(@credential, "session-1") }
    end
    audit = AuditLog.where(action: "companion.device.stale_credential", auditable: @device).sole
    assert_equal({ "device_id" => @device.obfuscated_id }, audit.data)
    assert_nil @device.reload.revoked_at
    assert_raises(CompanionDevice::RetryConflict) { CompanionDevice.create_session!(result["device_credential"], "session-1") }
    next_result = CompanionDevice.create_session!(result["device_credential"], "session-2")
    assert_equal @device, CompanionDevice.authenticate(next_result["device_credential"])
    assert_nil CompanionDevice.authenticate(result["device_credential"])
  end

  test "rejects other bearer namespaces and malformed request ids" do
    [ nil, [], "hx_#{'a' * 48}", "shcd_#{'a' * 1000}" ].each do |value|
      assert_nil CompanionDevice.authenticate(value)
      assert_raises(CompanionDevice::InvalidCredential) { CompanionDevice.create_session!(value, "session") }
    end
    [ nil, [], "x" * 129, "bad\nrequest" ].each do |request_id|
      assert_raises(ArgumentError) { CompanionDevice.create_session!(@credential, request_id) }
    end
  end

  test "revocation clears recovery and rejects credentials and outstanding tickets" do
    result = CompanionDevice.create_session!(@credential, "session-1")
    @device.revoke!(actor: users(:user_1))
    assert @device.reload.revoked_at
    assert_nil @device.session_response
    assert_nil CompanionDevice.authenticate(result["device_credential"])
    assert_raises(CompanionDevice::InvalidCredential) { CompanionDevice.create_session!(@credential, "session-1") }
    assert_nil CompanionCableTicket.redeem(result["cable_ticket"])
    audit = AuditLog.where(action: "companion.device.revoked", auditable: @device).sole
    assert_equal users(:user_1), audit.user
    assert_equal({ "device_id" => @device.obfuscated_id }, audit.data)
    @device.revoke!(actor: users(:user_1))
    assert_equal 1, AuditLog.where(action: "companion.device.revoked", auditable: @device).count
  end

  test "disabled accounts and paused devices cannot authenticate or recover" do
    result = CompanionDevice.create_session!(@credential, "session-1")
    @device.update!(paused: true)
    assert_nil CompanionDevice.authenticate(result["device_credential"])
    assert_equal result, CompanionDevice.create_session!(@credential, "session-1")
    assert_equal result, CompanionDevice.create_session!(result["device_credential"], "session-1")
    assert_raises(CompanionDevice::Paused) { CompanionDevice.create_session!(result["device_credential"], "different-request") }
    assert_nil CompanionCableTicket.redeem(result["cable_ticket"])
    @device.update!(paused: false)
    @account.update_columns(disabled_at: Time.current)
    assert_nil CompanionDevice.authenticate(result["device_credential"])
    assert_raises(CompanionDevice::InvalidCredential) { CompanionDevice.create_session!(@credential, "session-1") }
    assert_nil CompanionCableTicket.redeem(result["cable_ticket"])
  end

  test "tickets redeem exactly once and expire in 60 seconds" do
    freeze_time do
      result = CompanionDevice.create_session!(@credential, "session-1")
      assert_equal 60.seconds.from_now.iso8601(3), result["expires_at"]
      assert_equal @device, CompanionCableTicket.redeem(result["cable_ticket"])
      assert_nil CompanionCableTicket.redeem(result["cable_ticket"])
      assert_nil CompanionCableTicket.redeem(@credential)
      value, = CompanionCableTicket.issue!(@device)
      travel 60.seconds
      assert_nil CompanionCableTicket.redeem(value)
    end
  end

  test "tickets are revision-bound" do
    result = CompanionDevice.create_session!(@credential, "session-1")
    @device.update!(grant_revision: 2)
    assert_nil CompanionCableTicket.redeem(result["cable_ticket"])
  end

end
