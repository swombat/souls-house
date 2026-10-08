require "test_helper"
require "support/field_recording_helpers"

class Api::V1::Field::RecordingsControllerTest < ActionDispatch::IntegrationTest

  include FieldRecordingHelpers

  setup do
    @user = users(:user_1)
    @resident = agents(:research_assistant)
    @account = @resident.account
    key = ApiKey.generate_for(@user, name: "Field tests", agent: @resident)
    @headers = { "Authorization" => "Bearer #{key.raw_token}" }
    @recording = ready_recording(account: @account, user: @user, title: "Board call")
  end

  test "a resident reads transcripts with the names humans set, and nothing else" do
    @recording.speakers.first.name_as!(@account.field_voices.create!(name: "Priya"), by: @user)

    get api_v1_field_recordings_path, headers: @headers
    assert_response :success
    assert_equal [ "Board call" ], response.parsed_body["recordings"].map { |r| r["title"] }

    get api_v1_field_recording_path(@recording), headers: @headers
    body = response.parsed_body["recording"]
    assert_equal "[00:00] Priya: hello\n[00:02] Speaker 2: there", body["transcript_text"]
    assert_equal [ "Priya", "Speaker 2" ], body["speakers"].map { |s| s["name"] }
    json = response.body
    %w[audio voice_id field_voice print words naming_source].each { |key| assert_not_includes json, "\"#{key}" }
  end

  test "unfinished recordings have no transcript yet, and discarded ones are gone" do
    queued = queued_recording(account: @account, user: @user)
    get api_v1_field_recording_path(queued), headers: @headers
    assert_nil response.parsed_body.dig("recording", "transcript_text")

    @recording.discard_and_settle!
    get api_v1_field_recording_path(@recording), headers: @headers
    assert_response :not_found
  end

  test "another account's recordings can't be reached" do
    theirs = ready_recording(account: accounts(:another_team), user: @user)
    get api_v1_field_recording_path(theirs), headers: @headers
    assert_response :not_found
  end

end
