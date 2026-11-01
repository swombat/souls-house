require "test_helper"
require "support/field_recording_helpers"
require "support/api_human_key_helpers"

# Recordings with a person's key: what the browser gets (FieldRecordingsController).
class Api::V1::Field::HumanRecordingsTest < ActionDispatch::IntegrationTest

  include FieldRecordingHelpers
  include ApiHumanKeyHelpers
  include ActiveJob::TestHelper

  setup do
    Setting.instance.update!(allow_agents: true)
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @headers = human_headers(@user, @account)
    @recording = ready_recording(account: @account, user: @user, title: "Board call")
  end

  test "a person reads the audio, the timed words and speaker ids, but no suggestion or recognition data" do
    @recording.speakers.last.update!(suggested_name: "Tomás", suggestion_quote: "there", suggestion_source: "utility")
    get api_v1_field_recording_path(@recording), headers: @headers
    assert_response :success
    body = response.parsed_body["recording"]
    assert_equal audio_api_v1_field_recording_path(@recording), body["audio_path"]
    assert_equal %w[hello there], body["words"].select { |w| w["k"] == "w" }.map { |w| w["t"] }
    assert_equal [ 0, 500 ], body["words"].first.values_at("s", "e")
    assert_equal %w[speaker_0 speaker_1], body["speakers"].map { |s| s["label"] }
    assert_equal @recording.speakers.first.to_param, body["speakers"].first["id"]
    assert body["show_you_hint"]
    json = response.body
    assert_not_includes json, "Tomás"
    %w[suggest recogni print naming_source].each { |key| assert_not_includes json, "\"#{key}" }

    get audio_api_v1_field_recording_path(@recording), headers: @headers
    assert_response :redirect
  end

  test "a resident's detail is unchanged while audio is a separate download" do
    get api_v1_field_recording_path(@recording), headers: resident_headers(@user, agents(:research_assistant))
    assert_response :success
    %w[audio words].each { |key| assert_not_includes response.body, "\"#{key}" }

    get audio_api_v1_field_recording_path(@recording), headers: resident_headers(@user, agents(:research_assistant))
    assert_response :redirect
  end

  test "with the Field off audio is closed to everyone, but resident transcript and line reads remain open" do
    Setting.instance.update!(allow_agents: false)
    get api_v1_field_recording_path(@recording), headers: @headers
    assert_response :forbidden
    %w[audio words].each { |key| assert_not_includes response.body, "\"#{key}" }
    get api_v1_field_recordings_path, headers: @headers
    assert_response :forbidden
    get audio_api_v1_field_recording_path(@recording), headers: @headers
    assert_response :forbidden

    get api_v1_field_recording_path(@recording), headers: resident_headers(@user, agents(:research_assistant))
    assert_response :success
    assert_equal "Board call", response.parsed_body.dig("recording", "title")
    get lines_api_v1_field_recording_path(@recording), headers: resident_headers(@user, agents(:research_assistant))
    assert_response :success
    get audio_api_v1_field_recording_path(@recording), headers: resident_headers(@user, agents(:research_assistant))
    assert_response :forbidden
  end

  test "a person brings in a recording by claiming their direct upload" do
    blob = pinned_blob(account: @account, user: @user)
    assert_enqueued_with(job: FieldRecordings::ProbeJob) do
      post api_v1_field_recordings_path, params: { upload_id: blob.signed_id, title: "Standup", note: "Monday",
                                                   expected_speakers: 3 }, headers: @headers, as: :json
    end
    assert_response :created
    recording = @account.field_recordings.find(response.parsed_body.dig("recording", "id"))
    assert_equal [ "Standup", "Monday", 3, @user ], [ recording.title, recording.note, recording.expected_speakers, recording.uploaded_by ]
  end

  test "an upload pinned to someone else, or already used, can't be claimed" do
    theirs = pinned_blob(account: @account, user: users(:confirmed_user))
    post api_v1_field_recordings_path, params: { upload_id: theirs.signed_id }, headers: @headers, as: :json
    assert_response :unprocessable_entity

    post api_v1_field_recordings_path, params: { upload_id: @recording.audio.blob.signed_id }, headers: @headers, as: :json
    assert_response :unprocessable_entity

    blob = pinned_blob(account: @account, user: @user)
    post api_v1_field_recordings_path, params: { upload_id: blob.signed_id, expected_speakers: 99 }, headers: @headers, as: :json
    assert_response :unprocessable_entity
  end

  test "a person edits, retries and deletes a recording" do
    patch api_v1_field_recording_path(@recording), params: { title: "Board call, March" }, headers: @headers, as: :json
    assert_response :success
    assert_equal "Board call, March", @recording.reload.title

    patch api_v1_field_recording_path(@recording), params: { title: "x" * 201 }, headers: @headers, as: :json
    assert_response :unprocessable_entity

    post retry_api_v1_field_recording_path(@recording), headers: @headers
    assert_response :unprocessable_entity, "a ready recording can't be retried"

    @recording.update_columns(status: "failed")
    assert_enqueued_with(job: FieldRecordings::ProbeJob) do
      post retry_api_v1_field_recording_path(@recording), headers: @headers
    end
    assert_response :created
    assert_equal @recording, FieldRecording.find(response.parsed_body.dig("recording", "id")).retried_from

    delete api_v1_field_recording_path(@recording), headers: @headers
    assert_response :no_content
    assert @recording.reload.discarded?
  end

  test "a person redates a recording, clears the date, and an impossible date changes nothing" do
    patch api_v1_field_recording_path(@recording), params: { recorded_at: "2019-03-14" }, headers: @headers, as: :json
    assert_response :success
    assert_equal Time.zone.local(2019, 3, 14), @recording.reload.recorded_at
    assert_equal Time.zone.local(2019, 3, 14).iso8601, response.parsed_body.dig("recording", "recorded_at")

    patch api_v1_field_recording_path(@recording), params: { recorded_at: "2026-10-09T15:22:00+02:00" }, headers: @headers, as: :json
    assert_equal Time.utc(2026, 10, 9, 13, 22), @recording.reload.recorded_at, "an offset converts to UTC"

    patch api_v1_field_recording_path(@recording), params: { recorded_at: "2019-03-14T09:30:00Z" }, headers: @headers, as: :json
    assert_equal Time.utc(2019, 3, 14, 9, 30), @recording.reload.recorded_at

    %w[2019-02-30 2019-03-14T25:99:00Z 2019-03-14T09:30:00+99:99 yesterday].each do |bad|
      patch api_v1_field_recording_path(@recording), params: { title: "Renamed", recorded_at: bad }, headers: @headers, as: :json
      assert_response :unprocessable_entity, bad
      assert_match "recorded_at must be", response.parsed_body["error"]
    end
    @recording.reload
    assert_equal Time.utc(2019, 3, 14, 9, 30), @recording.recorded_at
    assert_equal "Board call", @recording.title, "a refused PATCH changes nothing"

    patch api_v1_field_recording_path(@recording), params: { recorded_at: "" }, headers: @headers, as: :json
    assert_response :success
    assert_nil @recording.reload.recorded_at
  end

  test "a person dismisses the 'is one of these you?' hint" do
    post dismiss_you_hint_api_v1_field_recordings_path, headers: @headers
    assert_response :no_content
    assert @user.reload.field_you_hint_dismissed_at
  end

  test "resident keys can't write, another account's recording is 404, and a former member reaches nothing" do
    resident = resident_headers(@user, agents(:research_assistant))
    patch api_v1_field_recording_path(@recording), params: { title: "Nope" }, headers: resident, as: :json
    assert_response :forbidden
    delete api_v1_field_recording_path(@recording), headers: resident
    assert_response :forbidden
    post dismiss_you_hint_api_v1_field_recordings_path, headers: resident
    assert_response :forbidden

    theirs = ready_recording(account: accounts(:another_team), user: @user)
    delete api_v1_field_recording_path(theirs), headers: @headers
    assert_response :not_found
    assert theirs.reload.kept?

    end_membership!(@user, @account)
    get api_v1_field_recording_path(@recording), headers: @headers
    assert_response :not_found
    delete api_v1_field_recording_path(@recording), headers: @headers
    assert_response :not_found
    assert @recording.reload.kept?
  end

  test "a recording arrives with its meeting's notes, and they can be changed or cleared" do
    blob = pinned_blob(account: @account, user: @user)
    post api_v1_field_recordings_path, params: { upload_id: blob.signed_id, title: "Standup", notes: "# Summary\n\nShipped." },
      headers: @headers, as: :json
    assert_response :created
    assert_equal "# Summary\n\nShipped.", response.parsed_body.dig("recording", "notes")
    recording = @account.field_recordings.find(response.parsed_body.dig("recording", "id"))
    assert_equal "# Summary\n\nShipped.", recording.notes

    get api_v1_field_recordings_path, headers: @headers
    listed = response.parsed_body["recordings"].find { |r| r["id"] == recording.to_param }
    assert_equal true, listed["has_notes"]
    assert_not listed.key?("notes"), "the list leaves notes out"

    patch api_v1_field_recording_path(recording), params: { notes: "# Summary\n\nShipped late." }, headers: @headers, as: :json
    assert_response :success
    assert_equal "# Summary\n\nShipped late.", recording.reload.notes

    patch api_v1_field_recording_path(recording), params: { notes: "x" * (FieldRecording::MAX_NOTES_LENGTH + 1) }, headers: @headers, as: :json
    assert_response :unprocessable_entity

    patch api_v1_field_recording_path(recording), params: { notes: "" }, headers: @headers, as: :json
    assert_response :success
    assert_nil recording.reload.notes
  end

end
