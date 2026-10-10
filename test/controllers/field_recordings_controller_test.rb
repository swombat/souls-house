require "test_helper"
require "support/field_recording_helpers"

class FieldRecordingsControllerTest < ActionDispatch::IntegrationTest

  include FieldRecordingHelpers

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    Setting.instance.update!(allow_agents: true)
    post login_path, params: { email_address: @user.email_address, password: "password123" }
  end

  test "declaring an upload returns a direct-upload URL and a pinned blob" do
    post account_field_recording_uploads_path(@account), params: {
      blob: { filename: "call.m4a", content_type: "audio/mp4", byte_size: 1234, checksum: "a" * 22 + "==" }
    }, as: :json

    assert_response :success
    body = response.parsed_body
    assert body["signed_id"].present?
    assert body.dig("direct_upload", "url").present?
    blob = ActiveStorage::Blob.find_signed(body["signed_id"])
    assert FieldRecording::Upload.pinned_to?(blob, account: @account, user: @user)
  end

  test "declaring a non-audio file is refused" do
    post account_field_recording_uploads_path(@account), params: {
      blob: { filename: "notes.txt", content_type: "text/plain", byte_size: 12, checksum: "a" * 22 + "==" }
    }, as: :json
    assert_response :unprocessable_entity
  end

  test "creating claims the upload and starts the probe" do
    blob = pinned_blob(account: @account, user: @user)

    assert_enqueued_with(job: FieldRecordings::ProbeJob) do
      post account_field_recordings_path(@account), params: {
        field_recording: { upload_id: blob.signed_id, title: "Board call", expected_speakers: 3 }
      }
    end
    recording = @account.field_recordings.last
    assert_equal "Board call", recording.title
    assert_equal 3, recording.expected_speakers
    assert_redirected_to account_field_path(@account, tab: "recordings", item: "recording-#{recording.to_param}")
  end

  test "a blob signed for something else can't become a recording" do
    message_blob = ActiveStorage::Blob.create_and_upload!(io: file_fixture("test_audio.mp3").open, filename: "voice.mp3")

    assert_no_difference -> { FieldRecording.count } do
      post account_field_recordings_path(@account), params: { field_recording: { upload_id: message_blob.signed_id } }
    end
    assert_redirected_to account_field_path(@account, tab: "recordings")
  end

  test "deleting discards and gives back unconsumed allowance" do
    recording = claimed_recording(account: @account, user: @user)
    recording.admit!(60_000)

    delete account_field_recording_path(@account, recording)
    assert recording.reload.discarded?
    assert_equal "released", recording.reservation.state
  end

  test "a discarded recording's audio is no longer served" do
    recording = claimed_recording(account: @account, user: @user)
    url = rails_blob_path(recording.audio, only_path: true)
    get url
    assert_response :redirect

    recording.discard_and_settle!
    get url
    assert_response :not_found
  end

  test "trying again makes a new recording from the same file" do
    recording = claimed_recording(account: @account, user: @user)
    recording.update_columns(status: "failed")

    assert_enqueued_with(job: FieldRecordings::ProbeJob) do
      post retry_account_field_recording_path(@account, recording)
    end
    again = @account.field_recordings.last
    assert_equal recording, again.retried_from
  end

  test "another account's recording is not found" do
    other = claimed_recording(account: accounts(:another_team), user: @user)
    delete account_field_recording_path(@account, other)
    assert_response :not_found
    assert other.reload.kept?
  end

  test "the Field page lists recordings and the allowance" do
    recording = claimed_recording(account: @account, user: @user, title: "Board call")
    recording.admit!(30.minutes.in_milliseconds)

    get account_field_path(@account, tab: "recordings")
    assert_response :success
    props = inertia_props["props"]
    assert_equal "recordings", props["tab"]
    assert_equal [ "Board call" ], props["items"].map { |r| r["title"] }
    assert_equal 30.minutes.in_milliseconds, props["recording_allowance"]["used_ms"]
    assert_equal 20.hours.in_milliseconds, props["recording_allowance"]["limit_ms"]
  end

  test "the transcript page gets a supplied transcript's turns, and no timed words" do
    recording = FieldRecording::Upload.claim!(
      account: @account, user: @user, signed_id: pinned_blob(account: @account, user: @user).signed_id,
      attributes: { title: "Archive", recorded_at: Time.utc(2026, 4, 7), source_path: "media/a.md" },
      supplied_turns: FieldRecording::SuppliedTranscript.parse("Anna: Hi.\nDaniel: Hello.\nAnna: Bye.")
    )
    get account_field_recording_path(@account, recording)
    props = inertia_props["props"]
    assert_equal [ "supplied", [], %w[Anna Daniel Anna] ],
      [ props.dig("recording", "transcript_source"), props.dig("recording", "words"),
        props.dig("recording", "turns").map { |turn| turn["spk"] } ]
    assert_equal "media/a.md", props.dig("recording", "source_path")
    assert_equal [ nil, nil ], props["speakers"].map { |speaker| speaker["talk_ms"] }
  end

end
