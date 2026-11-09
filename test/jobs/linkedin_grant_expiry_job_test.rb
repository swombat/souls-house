require "test_helper"
require "support/linkedin_test_helpers"

class LinkedinGrantExpiryJobTest < ActiveJob::TestCase

  include LinkedinTestHelpers
  include ActionMailer::TestHelper

  setup do
    @user = users(:user_1)
    @connection = linkedin_connection(account: accounts(:personal_account), user: @user,
                                      payload: { "expires_at" => 5.days.from_now.utc.iso8601 })
  end

  test "warns whoever connected it a week ahead, once per grant" do
    assert_enqueued_emails 1 do
      LinkedinGrantExpiryJob.perform_now
      LinkedinGrantExpiryJob.perform_now
    end
    assert_equal "connected", @connection.reload.status
  end

  test "says when it has ended, once, and marks it for reconnecting" do
    @connection.replace_credential_payload_without_reconciliation!(
      @connection.credential_payload_hash.merge("expires_at" => 1.hour.ago.utc.iso8601)
    )

    assert_enqueued_emails 1 do
      LinkedinGrantExpiryJob.perform_now
      LinkedinGrantExpiryJob.perform_now
    end
    assert_equal "reauthorizing", @connection.reload.status
  end

  test "a reconnect (a new end date) arms the notices again" do
    LinkedinGrantExpiryJob.perform_now
    @connection.replace_credential_payload_without_reconciliation!(
      @connection.credential_payload_hash.merge("expires_at" => 3.days.from_now.utc.iso8601)
    )

    assert_enqueued_emails 1 do
      LinkedinGrantExpiryJob.perform_now
    end
  end

  test "nothing is sent while the end is more than a week away" do
    @connection.replace_credential_payload_without_reconciliation!(
      @connection.credential_payload_hash.merge("expires_at" => 30.days.from_now.utc.iso8601)
    )

    assert_no_enqueued_emails { LinkedinGrantExpiryJob.perform_now }
  end

  # Mira's P2 on 169cdeae: the batch row can be stale by the time the lock
  # is taken. A reconnect that commits in between must be judged on its own
  # (fresh) grant, not the ended one the batch loaded.
  test "a reconnect committed after the batch was loaded is not marked ended" do
    @connection.replace_credential_payload_without_reconciliation!(
      @connection.credential_payload_hash.merge("expires_at" => 1.hour.ago.utc.iso8601)
    )
    stale = ServiceConnection.find(@connection.id)
    @connection.replace_credential_payload_without_reconciliation!(
      @connection.credential_payload_hash.merge("access_token" => "li-new", "expires_at" => 60.days.from_now.utc.iso8601)
    )

    assert_no_enqueued_emails { LinkedinGrantExpiryJob.new.send(:notify, stale, Time.current) }
    assert_equal "connected", @connection.reload.status
    assert_nil @connection.connector_state.to_h.dig("grant_notices", "ended_for")
  end

  test "a disconnect committed after the batch was loaded gets no notice" do
    @connection.replace_credential_payload_without_reconciliation!(
      @connection.credential_payload_hash.merge("expires_at" => 1.hour.ago.utc.iso8601)
    )
    stale = ServiceConnection.find(@connection.id)
    @connection.update_columns(status: "revoked")

    assert_no_enqueued_emails { LinkedinGrantExpiryJob.new.send(:notify, stale, Time.current) }
    assert_equal "revoked", @connection.reload.status
  end

  test "the email names the profile and the date" do
    mail = ServiceConnectionMailer.grant_expiring(@connection, 5.days.from_now)

    assert_equal [ @user.email_address ], mail.to
    assert_match(/LinkedIn connection ends on/, mail.subject)
    assert_match(/Daniel Tenner/, mail.text_part.body.to_s)
  end

end
