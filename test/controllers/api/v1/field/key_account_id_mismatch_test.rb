require "test_helper"
require "support/field_recording_helpers"
require "support/api_human_key_helpers"

# Mira's round-3 finding on #229: a person's key minted for account A, sent
# with account_id=B, must be refused (404), never quietly act in A. The person
# belongs to both accounts, so this is about the key's scope, not membership.
# Every mutating endpoint here asserts that neither account's data changed.
class Api::V1::Field::KeyAccountIdMismatchTest < ActionDispatch::IntegrationTest

  include FieldRecordingHelpers
  include ApiHumanKeyHelpers

  setup do
    Setting.instance.update!(allow_agents: true)
    @user = users(:existing_user)
    @a = accounts(:existing_user_account)
    @b = accounts(:team_account)
    @key = human_headers(@user, @a)
    @to_b = { account_id: @b.to_param }

    @voice_a = @a.field_voices.create!(name: "Ana")
    @voice_b = @b.field_voices.create!(name: "Bea")
    store_print!(@voice_a)
    store_print!(@voice_b)
    @a.update!(recognise_voices: false)
    @b.update!(recognise_voices: false)
  end

  def prints(account) = FieldVoiceprint.where(account: account).count

  test "forget all voices with account_id of another account is 404 and forgets nothing in either" do
    assert_no_difference -> { FieldVoiceprint.count } do
      delete forget_all_api_v1_field_voices_path(@to_b), headers: @key
      assert_response :not_found
    end
    assert_equal [ 1, 1 ], [ prints(@a), prints(@b) ]

    # The key's own account, named or not, still works and touches only it.
    delete forget_all_api_v1_field_voices_path(account_id: @a.to_param), headers: @key
    assert_response :no_content
    assert_equal [ 0, 1 ], [ prints(@a), prints(@b) ]
  end

  test "the recognition setting with account_id of another account is 404 and changes neither" do
    patch recognition_api_v1_field_voices_path(@to_b), params: { recognise_voices: true }, headers: @key, as: :json
    assert_response :not_found
    assert_equal [ false, false ], [ @a.reload.recognise_voices, @b.reload.recognise_voices ]

    patch recognition_api_v1_field_voices_path, params: { recognise_voices: true }, headers: @key, as: :json
    assert_response :success
    assert_equal [ true, false ], [ @a.reload.recognise_voices, @b.reload.recognise_voices ]
  end

  test "upload declaration, recording create and the you-hint with another account_id are 404 and create nothing" do
    declaration = { blob: { filename: "call.webm", content_type: "audio/webm", byte_size: 1024, checksum: "#{'A' * 22}==" } }
    assert_no_difference -> { ActiveStorage::Blob.count } do
      post api_v1_field_recording_uploads_path(@to_b), params: declaration, headers: @key, as: :json
      assert_response :not_found
    end

    blob = pinned_blob(account: @a, user: @user)
    assert_no_difference -> { FieldRecording.count } do
      post api_v1_field_recordings_path(@to_b), params: { upload_id: blob.signed_id, title: "Wrong place" },
        headers: @key, as: :json
      assert_response :not_found
    end

    post dismiss_you_hint_api_v1_field_recordings_path(@to_b), headers: @key
    assert_response :not_found
    assert_nil @user.reload.field_you_hint_dismissed_at

    # Own account: the same create succeeds.
    post api_v1_field_recordings_path, params: { upload_id: blob.signed_id, title: "Right place" }, headers: @key, as: :json
    assert_response :created
    assert_equal @a, FieldRecording.find_by!(title: "Right place").account
  end

  test "the key's own records with another account_id are 404 and unchanged" do
    recording = ready_recording(account: @a, user: @user, title: "Call")
    speaker = recording.speakers.first
    file = @a.field_files.create!(title: "Notes", file: Rack::Test::UploadedFile.new(file_fixture("test.txt"), "text/plain"),
                                  uploaded_by: @user)
    whiteboard = @a.whiteboards.create!(name: "Plans", content: "x")
    enrolment = FieldVoiceEnrolment.create!(account: @a, field_voice: @voice_a, field_recording_speaker: speaker,
      start_generation: 0, sample_ms: 12_000, consent_text_version: FieldVoiceprints::CONSENT_TEXT_VERSION,
      consented_by: @user, expires_at: 10.minutes.from_now)

    patch api_v1_field_recording_path(recording, @to_b), params: { title: "No" }, headers: @key, as: :json
    assert_response :not_found
    post retry_api_v1_field_recording_path(recording, @to_b), headers: @key
    assert_response :not_found
    patch api_v1_field_recording_speaker_path(recording, speaker, @to_b), params: { name: "No" }, headers: @key, as: :json
    assert_response :not_found
    patch api_v1_field_file_path(file, @to_b), params: { title: "No" }, headers: @key, as: :json
    assert_response :not_found
    patch api_v1_field_voice_path(@voice_a, @to_b), params: { name: "No" }, headers: @key, as: :json
    assert_response :not_found
    delete forget_api_v1_field_voice_path(@voice_a, @to_b), headers: @key
    assert_response :not_found
    delete api_v1_field_voice_path(@voice_a, @to_b), headers: @key
    assert_response :not_found
    delete api_v1_field_enrolment_path(enrolment, @to_b), headers: @key
    assert_response :not_found
    delete api_v1_whiteboard_path(whiteboard, @to_b), headers: @key
    assert_response :not_found
    delete api_v1_field_recording_path(recording, @to_b), headers: @key
    assert_response :not_found

    assert_equal [ "Call", "Notes", "Ana", nil ], [ recording.reload.title, file.reload.title, @voice_a.reload.name, whiteboard.reload.deleted_at ]
    assert recording.kept?
    assert @voice_a.kept?
    assert_nil speaker.reload.field_voice_id
    assert FieldVoiceEnrolment.exists?(enrolment.id)
    assert_equal [ 1, 1 ], [ prints(@a), prints(@b) ]
  end

  test "reads with another account_id are 404" do
    get api_v1_field_voices_path(@to_b), headers: @key
    assert_response :not_found
    get api_v1_field_limits_path(@to_b), headers: @key
    assert_response :not_found
    get api_v1_field_recordings_path(@to_b), headers: @key
    assert_response :not_found
    get api_v1_device_streams_path(@to_b), headers: @key
    assert_response :not_found
  end

  test "device streams with another account_id are 404 and unchanged" do
    stream = DeviceStream.create!(account: @a, subject_user: @user, name: "Strap", enabled: true)
    credential = stream.device_stream_credentials.create!(token_digest: SecureRandom.hex(32))
    session = stream.device_stream_sessions.create!(session_uuid: SecureRandom.uuid)

    assert_no_difference -> { DeviceStream.count } do
      post api_v1_device_streams_path(@to_b), params: { name: "Wrong place" }, headers: @key, as: :json
      assert_response :not_found
    end
    assert_no_difference -> { DeviceStreamCredential.count } do
      post credential_api_v1_device_stream_path(stream.stream_key, @to_b), headers: @key
      assert_response :not_found
    end
    patch api_v1_device_stream_path(stream.stream_key, @to_b), params: { enabled: false }, headers: @key, as: :json
    assert_response :not_found
    delete revoke_credential_api_v1_device_stream_path(stream.stream_key, credential.to_param, @to_b), headers: @key
    assert_response :not_found
    delete erase_session_api_v1_device_stream_path(stream.stream_key, session.session_uuid, @to_b), headers: @key
    assert_response :not_found
    delete api_v1_device_stream_path(stream.stream_key, @to_b), headers: @key
    assert_response :not_found

    assert stream.reload.enabled?
    assert_nil stream.erased_at
    assert_nil credential.reload.revoked_at
    assert_nil session.reload.erased_at
  end

  # Recovery stays subject-only: after leaving A, the key still recovers A's
  # stream, with or without naming A.
  test "device-stream recovery after leaving the key's account is unchanged" do
    stream = DeviceStream.create!(account: @a, subject_user: @user, name: "Strap", enabled: true)
    credential = stream.device_stream_credentials.create!(token_digest: SecureRandom.hex(32))
    end_membership!(@user, @a)

    get api_v1_device_streams_path(account_id: @a.to_param), headers: @key
    assert_response :success
    assert_equal [ stream.stream_key ], response.parsed_body["device_streams"].map { |s| s["id"] }
    delete revoke_credential_api_v1_device_stream_path(stream.stream_key, credential.to_param, account_id: @a.to_param),
      headers: @key
    assert_response :no_content
    delete api_v1_device_stream_path(stream.stream_key), headers: @key
    assert_response :no_content
    assert stream.reload.erased_at
  end

end
