require "test_helper"
require "support/app_oauth_test_helper"
require "support/field_recording_helpers"
require "support/api_human_key_helpers"

# Field, whiteboards and device streams with a person's OAuth app token. A
# token belongs to the person, not an account: a resource in any enabled
# account they belong to is reachable by its id alone and is authorised
# against its own account; account_id narrows to one account.
class Api::V1::Field::OauthFieldDevicesTest < ActionDispatch::IntegrationTest

  include AppOauthTestHelper
  include FieldRecordingHelpers
  include ApiHumanKeyHelpers
  include ActiveJob::TestHelper

  setup do
    Setting.instance.update!(allow_agents: true)
    @user = users(:existing_user)
    @personal = accounts(:existing_user_account)
    @team = accounts(:team_account) # the second, non-default account
    @user.update_columns(default_account_id: @personal.id)
    @client = create_app_client
    @tokens = sign_in_device
    @headers = bearer(@tokens)

    @recording = ready_recording(account: @team, user: @user, title: "Team call")
    @speaker = @recording.speakers.first
    @file = @team.field_files.create!(title: "Notes", file: Rack::Test::UploadedFile.new(file_fixture("test.txt"), "text/plain"),
                                      uploaded_by: @user)
    @voice = @team.field_voices.create!(name: "Tomás")
    @whiteboard = @team.whiteboards.create!(name: "Plans", content: "x")
    @stream = DeviceStream.create!(account: @team, subject_user: @user, name: "Team strap", enabled: false)
  end

  test "writes on Field resources in the second account work without account_id, in that account" do
    assert_no_difference -> { AuditLog.count } do # the web writes no audit rows for these either
      get api_v1_field_recording_path(@recording), headers: @headers
      assert_response :success
      assert_equal "Team call", response.parsed_body.dig("recording", "title")

      patch api_v1_field_recording_path(@recording), params: { title: "Renamed" }, headers: @headers, as: :json
      assert_response :success
      assert_equal "Renamed", @recording.reload.title

      patch api_v1_field_recording_speaker_path(@recording, @speaker), params: { name: "Priya" }, headers: @headers, as: :json
      assert_response :success
      assert_equal @team, @speaker.reload.field_voice.account, "the new voice belongs to the recording's account"

      patch api_v1_field_file_path(@file), params: { note: "From my agent" }, headers: @headers, as: :json
      assert_response :success
      assert_equal "From my agent", @file.reload.note

      patch api_v1_field_voice_path(@voice), params: { name: "Tom" }, headers: @headers, as: :json
      assert_response :success
      assert_equal "Tom", @voice.reload.name

      delete api_v1_whiteboard_path(@whiteboard), headers: @headers
      assert_response :no_content
      assert @whiteboard.reload.deleted_at
    end
  end

  test "account_id selects the account for collections and creates" do
    get api_v1_field_voices_path(account_id: @team.to_param), headers: @headers
    assert_response :success
    assert_equal [ "Tomás" ], response.parsed_body["voices"].map { |v| v["name"] }

    get api_v1_field_voices_path, headers: @headers
    assert_response :success
    assert_empty response.parsed_body["voices"], "without account_id: the default account"

    get api_v1_field_recordings_path(account_id: @team.to_param), headers: @headers
    assert_equal [ @recording.to_param ], response.parsed_body["recordings"].map { |r| r["id"] }

    blob = pinned_blob(account: @team, user: @user)
    post api_v1_field_recordings_path(account_id: @team.to_param), params: { upload_id: blob.signed_id, title: "Standup" },
      headers: @headers, as: :json
    assert_response :created
    assert @team.field_recordings.exists?(title: "Standup")

    patch recognition_api_v1_field_voices_path(account_id: @team.to_param), params: { recognise_voices: true },
      headers: @headers, as: :json
    assert_response :success
    assert @team.reload.recognise_voices
    assert_not @personal.reload.recognise_voices
  end

  test "account_id naming another of the person's accounts doesn't reach the resource" do
    other = { account_id: @personal.to_param }
    get api_v1_field_recording_path(@recording, other), headers: @headers
    assert_response :not_found
    patch api_v1_field_recording_path(@recording, other), params: { title: "No" }, headers: @headers, as: :json
    assert_response :not_found
    patch api_v1_field_recording_speaker_path(@recording, @speaker, other), params: { name: "No" }, headers: @headers, as: :json
    assert_response :not_found
    patch api_v1_field_file_path(@file, other), params: { title: "No" }, headers: @headers, as: :json
    assert_response :not_found
    patch api_v1_field_voice_path(@voice, other), params: { name: "No" }, headers: @headers, as: :json
    assert_response :not_found
    delete api_v1_whiteboard_path(@whiteboard, other), headers: @headers
    assert_response :not_found
    patch api_v1_device_stream_path(@stream.stream_key, other), params: { enabled: true }, headers: @headers, as: :json
    assert_response :not_found

    assert_equal [ "Team call", "Notes", "Tomás", nil, false ],
      [ @recording.reload.title, @file.reload.title, @voice.reload.name, @whiteboard.reload.deleted_at, @stream.reload.enabled? ]
  end

  test "a disabled account and a departed member both get 404" do
    @team.update_columns(disabled_at: Time.current)
    get api_v1_field_recording_path(@recording), headers: @headers
    assert_response :not_found
    patch api_v1_field_voice_path(@voice), params: { name: "No" }, headers: @headers, as: :json
    assert_response :not_found
    get api_v1_field_voices_path(account_id: @team.to_param), headers: @headers
    assert_response :not_found

    @team.update_columns(disabled_at: nil)
    memberships(:team_member).destroy!
    get api_v1_field_recording_path(@recording), headers: @headers
    assert_response :not_found
    delete api_v1_whiteboard_path(@whiteboard), headers: @headers
    assert_response :not_found
    patch api_v1_device_stream_path(@stream.stream_key), params: { enabled: true }, headers: @headers, as: :json
    assert_response :not_found
    assert_equal [ "Tomás", nil, false ], [ @voice.reload.name, @whiteboard.reload.deleted_at, @stream.reload.enabled? ]

    # The subject keeps recovery after leaving, as on the web's personal page.
    get api_v1_device_stream_path(@stream.stream_key), headers: @headers
    assert_response :success
    delete api_v1_device_stream_path(@stream.stream_key), headers: @headers
    assert_response :no_content
  end

  test "device streams: every account without account_id, one account with it" do
    mine = DeviceStream.create!(account: @personal, subject_user: @user, name: "Home strap")

    get api_v1_device_streams_path, headers: @headers
    assert_response :success
    assert_equal [ mine.stream_key, @stream.stream_key ].sort, response.parsed_body["device_streams"].map { |s| s["id"] }.sort

    get api_v1_device_streams_path(account_id: @team.to_param), headers: @headers
    assert_equal [ @stream.stream_key ], response.parsed_body["device_streams"].map { |s| s["id"] }

    patch api_v1_device_stream_path(@stream.stream_key), params: { enabled: true }, headers: @headers, as: :json
    assert_response :success
    assert @stream.reload.enabled?

    post credential_api_v1_device_stream_path(@stream.stream_key), headers: @headers
    assert_response :created

    post api_v1_device_streams_path(account_id: @team.to_param), params: { name: "Second" }, headers: @headers, as: :json
    assert_response :created
    assert_equal @team, DeviceStream.find_by!(stream_key: response.parsed_body.dig("device_stream", "id")).account
  end

  test "a resident key is refused" do
    resident = resident_headers(users(:user_1), agents(:research_assistant))
    patch api_v1_field_voice_path(@voice), params: { name: "No" }, headers: resident, as: :json
    assert_response :forbidden
    get api_v1_device_streams_path, headers: resident
    assert_response :forbidden
    delete api_v1_whiteboard_path(@whiteboard), headers: resident
    assert_response :forbidden
  end

end
