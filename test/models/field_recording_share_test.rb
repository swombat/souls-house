require "test_helper"
require "support/field_recording_helpers"

class FieldRecordingShareTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @recording = ready_recording(account: @account, user: @user, title: "Board call")
  end

  test "a link keeps only the digest of its token and finds itself by the token" do
    share = FieldRecordingShare.issue!(recording: @recording, user: @user)

    assert_match FieldRecordingShare::TOKEN_FORMAT, share.token
    assert_equal Digest::SHA256.hexdigest(share.token), share.token_digest
    refute_includes share.attributes.values.map(&:to_s), share.token
    assert_equal share, FieldRecordingShare.find_by_token(share.token)
    assert_nil FieldRecordingShare.find_by(id: share.id).token, "the token is not readable again"
  end

  test "expiry defaults to one day and takes 1h, 1w or never" do
    freeze_time do
      assert_equal 1.day.from_now, FieldRecordingShare.issue!(recording: @recording, user: @user).expires_at
      assert_equal 1.day.from_now, FieldRecordingShare.issue!(recording: @recording, user: @user, expiry: "").expires_at
      assert_equal 1.hour.from_now, FieldRecordingShare.issue!(recording: @recording, user: @user, expiry: "1h").expires_at
      assert_equal 1.week.from_now, FieldRecordingShare.issue!(recording: @recording, user: @user, expiry: "1w").expires_at
      assert_nil FieldRecordingShare.issue!(recording: @recording, user: @user, expiry: "never").expires_at
    end
    assert_raises(FieldRecordingShare::Invalid) { FieldRecordingShare.issue!(recording: @recording, user: @user, expiry: "1y") }
  end

  test "a link is viewable only while live and while its recording is kept and ready" do
    share = FieldRecordingShare.issue!(recording: @recording, user: @user, expiry: "1h")
    assert share.viewable?

    travel 61.minutes do
      assert share.expired?
      refute share.viewable?
    end

    forever = FieldRecordingShare.issue!(recording: @recording, user: @user, expiry: "never")
    forever.revoke!
    refute forever.reload.viewable?

    live = FieldRecordingShare.issue!(recording: @recording, user: @user, expiry: "never")
    @recording.discard!
    refute live.reload.viewable?, "deleting the recording ends its links"
  end

  test "only a ready, kept recording can be shared" do
    queued = queued_recording(account: @account, user: @user)
    assert_raises(FieldRecordingShare::Invalid) { FieldRecordingShare.issue!(recording: queued, user: @user) }
  end

  test "a recording holds a bounded number of live links" do
    FieldRecordingShare::MAX_ACTIVE_PER_RECORDING.times { FieldRecordingShare.issue!(recording: @recording, user: @user) }
    assert_raises(FieldRecordingShare::Invalid) { FieldRecordingShare.issue!(recording: @recording, user: @user) }
    @recording.shares.first.revoke!
    assert FieldRecordingShare.issue!(recording: @recording, user: @user)
  end

  test "lookups refuse anything shaped unlike a token" do
    assert_nil FieldRecordingShare.find_by_token(nil)
    assert_nil FieldRecordingShare.find_by_token("sht_short")
    assert_nil FieldRecordingShare.find_by_token("sht_" + "a" * 43)
  end

end
