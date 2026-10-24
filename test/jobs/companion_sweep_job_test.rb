require "test_helper"

class CompanionSweepJobTest < ActiveJob::TestCase

  test "clears session ciphertext exactly at expiry without losing active recovery or stale audit metadata" do
    freeze_time do
      device, credential, = enroll_fixture
      response = CompanionDevice.create_session!(credential, "session-request")
      previous_digest = device.reload.previous_credential_digest

      travel 59.seconds
      CompanionSweepJob.perform_now
      assert device.reload.ciphertext_for(:session_response)
      assert_equal response, CompanionDevice.create_session!(credential, "session-request")

      travel 1.second
      CompanionSweepJob.perform_now
      assert_nil device.reload.session_response
      assert_nil device.ciphertext_for(:session_response)
      assert_equal previous_digest, device.previous_credential_digest
      assert_equal "session-request", device.session_request_id
      assert_raises(CompanionDevice::InvalidCredential) do
        CompanionDevice.create_session!(credential, "session-request")
      end
      assert_equal({ "device_id" => device.obfuscated_id },
        AuditLog.where(action: "companion.device.stale_credential", auditable: device).sole.data)
      assert_nil device.reload.revoked_at
      assert_equal device, CompanionDevice.authenticate(response.fetch("device_credential"))
      assert CompanionDevice.create_session!(response.fetch("device_credential"), "fresh-request")
      CompanionSweepJob.perform_now
      assert device.reload.session_response, "a fresh rotation cache must survive another sweep"
    end
  end

  test "clears enrollment ciphertext exactly at expiry while retaining consumed grant and device" do
    freeze_time do
      device, credential, grant, token, response = enroll_fixture
      travel 599.seconds
      CompanionSweepJob.perform_now
      assert grant.reload.ciphertext_for(:enrollment_response)
      assert_equal response, CompanionEnrollmentGrant.enroll!(token, "sweep-fixture").fetch(2)

      travel 1.second
      CompanionSweepJob.perform_now
      assert_nil grant.reload.enrollment_response
      assert_nil grant.ciphertext_for(:enrollment_response)
      assert grant.consumed_at
      assert_nil CompanionEnrollmentGrant.enroll!(token, "sweep-fixture")
      assert_equal device, CompanionDevice.authenticate(credential)
      assert_equal 1, CompanionDevice.where(companion_enrollment_grant: grant).count
    end
  end

  test "deletes expired bodies inclusively and preserves active bodies and operation audit rows" do
    freeze_time do
      device, = enroll_fixture
      expired, at_boundary, active = [ 1.second.ago, Time.current, 1.second.from_now ].map do |expiry|
        operation = CompanionOperation.create!(companion_device: device, agent: agents(:research_assistant),
          kind: "read", arguments: {}, state: "completed", connection_epoch: "sweep-epoch",
          grant_revision: 1, deadline: 30.seconds.from_now, outcome: "ok")
        operation.create_body!(data: "synthetic-private-body", content_type: "application/octet-stream", expires_at: expiry)
      end

      assert_no_difference "CompanionOperation.count" do
        assert_difference "CompanionOperationBody.count", -2 do
          CompanionSweepJob.perform_now
        end
      end
      assert_not CompanionOperationBody.exists?(expired.id)
      assert_not CompanionOperationBody.exists?(at_boundary.id)
      assert CompanionOperationBody.exists?(active.id)
      CompanionSweepJob.perform_now
      assert CompanionOperationBody.exists?(active.id), "sweeping twice is safe"
      travel 1.second
      CompanionSweepJob.perform_now
      assert_not CompanionOperationBody.exists?(active.id)
    end
  end

  private

  def enroll_fixture
    agent = agents(:research_assistant)
    grant = CompanionEnrollmentGrant.create!(account: agent.account, minting_agent: agent,
      created_by_user: users(:user_1), name: "Sweep fixture", device_request_id: "sweep-fixture",
      policy: { "residents" => [ { "id" => agent.obfuscated_id, "volumes" => [], "execute" => false } ] },
      expires_at: 1.hour.from_now)
    token = grant.issue_token!(agent)
    device, credential, response = CompanionEnrollmentGrant.enroll!(token, "sweep-fixture")
    [ device, credential, grant, token, response ]
  end

end
