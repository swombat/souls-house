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

  test "the email names the profile and the date" do
    mail = ServiceConnectionMailer.grant_expiring(@connection, 5.days.from_now)

    assert_equal [ @user.email_address ], mail.to
    assert_match(/LinkedIn connection ends on/, mail.subject)
    assert_match(/Daniel Tenner/, mail.text_part.body.to_s)
  end

end
