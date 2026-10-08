require "test_helper"
require "support/field_recording_helpers"

class FieldRecording::UploadTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
  end

  def claim(blob, account: @account, user: @user)
    FieldRecording::Upload.claim!(account:, user:, signed_id: blob.signed_id, attributes: { title: "Call" })
  end

  test "a pinned upload is claimed once" do
    blob = pinned_blob(account: @account, user: @user)
    recording = claim(blob)
    assert_equal blob, recording.audio.blob
    assert_equal @user, recording.uploaded_by
    assert_nil claim(blob)
  end

  test "another user's or another account's upload is refused" do
    blob = pinned_blob(account: @account, user: @user)
    assert_nil claim(blob, user: users(:existing_user))
    assert_nil claim(blob, account: accounts(:team_account))
  end

  test "an expired pin is refused" do
    blob = pinned_blob(account: @account, user: @user)
    travel FieldRecording::Upload::TTL + 1.minute do
      assert_nil claim(blob)
    end
  end

  test "a blob without a pin, or with a forged one, is refused" do
    plain = ActiveStorage::Blob.create_and_upload!(io: file_fixture("test_audio.mp3").open, filename: "a.mp3")
    assert_nil claim(plain)

    forged = ActiveStorage::Blob.create_and_upload!(
      io: file_fixture("test_audio.mp3").open, filename: "a.mp3",
      metadata: { FieldRecording::Upload::METADATA_KEY => { "account_id" => @account.id, "user_id" => @user.id }.to_json }
    )
    assert_nil claim(forged)
  end

  test "a blob already attached elsewhere is refused even with a valid pin" do
    blob = pinned_blob(account: @account, user: @user)
    @account.field_files.create!(title: "Elsewhere", file: blob, uploaded_by: @user)
    assert_nil claim(blob)
  end

  test "declarations must be audio or video under the size cap" do
    good = { filename: "a.m4a", content_type: "audio/mp4", byte_size: 10, checksum: "a" * 22 + "==" }
    assert FieldRecording::Upload.valid_declaration?(**good)
    assert_not FieldRecording::Upload.valid_declaration?(**good, content_type: "text/plain")
    assert_not FieldRecording::Upload.valid_declaration?(**good, byte_size: FieldRecording::MAX_BYTES + 1)
    assert_not FieldRecording::Upload.valid_declaration?(**good, checksum: "nope")
  end

end
