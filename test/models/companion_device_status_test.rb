require "test_helper"

# The Computers page reloads when a computer connects, drops or changes. A
# permission change drops the connection on purpose, so without this marker
# the page kept showing "Offline" after the companion was back.
class CompanionDeviceStatusTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  setup do
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    grant = CompanionEnrollmentGrant.create!(account: @account, minting_agent: @agent,
      created_by_user: users(:user_1), name: "Synthetic device", device_request_id: "device-request",
      policy: { "residents" => [ { "id" => @agent.obfuscated_id, "volumes" => [], "execute" => false } ] },
      expires_at: 1.hour.from_now)
    @device, = CompanionEnrollmentGrant.enroll!(grant.issue_token!(@agent), "device-request")
    @stream = "ComputerStatus:#{@account.to_param}"
  end

  test "connecting and dropping each tell the page once, with no device data" do
    assert_equal [ { "action" => "refresh" } ], capture_broadcasts(@stream) { @device.update!(connection_epoch: SecureRandom.uuid) }
    assert_equal [ { "action" => "refresh" } ], capture_broadcasts(@stream) { @device.update!(connection_epoch: nil) }
  end

  test "pause and a permission change tell the page" do
    assert_broadcasts(@stream, 1) { @device.apply_control!("pause") }
    @device.apply_control!("resume")
    assert_broadcasts(@stream, 1) do
      @device.change_resident_authority!(resident_id: @agent.obfuscated_id, actor: users(:user_1), execute: true)
    end
  end

  test "credential bookkeeping and other accounts stay quiet" do
    assert_no_broadcasts(@stream) { @device.update!(session_request_id: "another-request") }
    assert_no_broadcasts("ComputerStatus:#{accounts(:existing_user_account).to_param}") do
      @device.update!(connection_epoch: SecureRandom.uuid)
    end
  end

  test "a rolled-back change says nothing" do
    assert_no_broadcasts(@stream) do
      CompanionDevice.transaction do
        @device.update!(connection_epoch: SecureRandom.uuid)
        raise ActiveRecord::Rollback
      end
    end
  end

end
