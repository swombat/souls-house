require "test_helper"

class Api::V1::Companion::SessionsControllerTest < ActionDispatch::IntegrationTest

  setup do
    agent = agents(:research_assistant)
    grant = CompanionEnrollmentGrant.create!(account: agent.account, minting_agent: agent,
      created_by_user: users(:user_1), name: "Session review fixture", device_request_id: "session-fixture",
      policy: { "residents" => [ { "id" => agent.obfuscated_id, "volumes" => [], "execute" => false } ] },
      expires_at: 1.hour.from_now)
    @device, @credential = CompanionEnrollmentGrant.enroll!(grant.issue_token!(agent), "session-fixture")
  end

  test "paused session is 423 without rotation and resumes with the same credential" do
    @device.update!(paused: true)
    assert_no_difference "CompanionCableTicket.count" do
      session_request(@credential)
      assert_response :locked
    end
    assert_equal({ "error" => "Device paused", "code" => "paused" }, response.parsed_body)
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal CompanionDevice.digest(@credential), @device.reload.credential_digest
    assert_nil @device.revoked_at

    @device.update!(paused: false)
    session_request(@credential)
    assert_response :created
  end

  test "paused exact recovery preserves the lost response without authorizing Cable" do
    session_request(@credential)
    assert_response :created
    next_credential = response.parsed_body.fetch("device_credential")
    saved = response.parsed_body
    @device.update!(paused: true)
    [ @credential, next_credential ].each do |credential|
      session_request(credential)
      assert_response :created
      assert_equal saved, response.parsed_body
      assert_nil CompanionCableTicket.redeem(saved.fetch("cable_ticket"))
    end
    session_request(next_credential, request_id: "different-request")
    assert_response :locked
    travel 61.seconds
    @device.update!(paused: false)
    session_request(next_credential, request_id: "after-resume")
    assert_response :created
    resumed_credential = response.parsed_body.fetch("device_credential")
    assert_not AuditLog.where(action: "companion.device.stale_credential", auditable: @device).exists?
    session_request(CompanionDevice.generate_credential)
    assert_response :unauthorized

    @device.revoke!
    session_request(resumed_credential)
    assert_response :unauthorized
  end

  test "expired previous credential is safely audited and refused without revoking current credential" do
    session_request(@credential)
    assert_response :created
    next_credential = response.parsed_body.fetch("device_credential")
    travel 61.seconds
    assert_difference -> { AuditLog.where(action: "companion.device.stale_credential", auditable: @device).count }, 1 do
      session_request(@credential)
      assert_response :unauthorized
    end
    assert_equal({ "device_id" => @device.obfuscated_id },
      AuditLog.where(action: "companion.device.stale_credential", auditable: @device).sole.data)
    assert_nil @device.reload.revoked_at
    session_request(next_credential, request_id: "fresh-request")
    assert_response :created
  end

  private

  def session_request(credential, request_id: "review-request")
    post "/api/v1/companion/session", params: { request_id: request_id },
      headers: { "Authorization" => "Bearer #{credential}" }, as: :json
  end

end
