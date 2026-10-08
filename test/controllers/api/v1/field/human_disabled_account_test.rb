require "test_helper"
require "support/field_recording_helpers"
require "support/api_human_key_helpers"

# Mira's P1 on #229: a person's key for an account that has since been
# disabled must reach none of the normal Field, whiteboard or device-stream
# controls (the browser only finds enabled confirmed accounts). Device-stream
# recovery (list, read, revoke, erase, close) stays open to the subject, as on
# the web's personal page.
class Api::V1::Field::HumanDisabledAccountTest < ActionDispatch::IntegrationTest

  include FieldRecordingHelpers
  include ApiHumanKeyHelpers

  setup do
    Setting.instance.update!(allow_agents: true)
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @headers = human_headers(@user, @account)
    @recording = ready_recording(account: @account, user: @user, title: "Board call")
    @speaker = @recording.speakers.first
    @file = @account.field_files.create!(title: "Notes", file: Rack::Test::UploadedFile.new(file_fixture("test.txt"), "text/plain"),
                                         uploaded_by: @user)
    @voice = @account.field_voices.create!(name: "Tomás")
    @whiteboard = @account.whiteboards.create!(name: "Plans", content: "x")
    @stream = DeviceStream.create!(account: @account, subject_user: @user, name: "Strap", enabled: false)
    @account.update_columns(disabled_at: Time.current)
  end

  test "a disabled account's key reaches no Field, voice or whiteboard control" do
    requests = [
      [ :get, api_v1_field_limits_path ],
      [ :get, api_v1_field_recordings_path ],
      [ :get, api_v1_field_recording_path(@recording) ],
      [ :get, audio_api_v1_field_recording_path(@recording) ],
      [ :patch, api_v1_field_recording_path(@recording), { title: "Renamed" } ],
      [ :post, retry_api_v1_field_recording_path(@recording) ],
      [ :post, api_v1_field_recordings_path, { upload_id: "x" } ],
      [ :post, api_v1_field_recording_uploads_path,
        { blob: { filename: "a.webm", content_type: "audio/webm", byte_size: 10, checksum: "x" } } ],
      [ :post, dismiss_you_hint_api_v1_field_recordings_path ],
      [ :patch, api_v1_field_recording_speaker_path(@recording, @speaker), { name: "Priya" } ],
      [ :patch, api_v1_field_file_path(@file), { title: "Renamed" } ],
      [ :get, api_v1_field_voices_path ],
      [ :patch, api_v1_field_voice_path(@voice), { name: "Tom" } ],
      [ :delete, forget_api_v1_field_voice_path(@voice) ],
      [ :delete, forget_all_api_v1_field_voices_path ],
      [ :patch, recognition_api_v1_field_voices_path, { recognise_voices: true } ],
      [ :delete, api_v1_field_voice_path(@voice) ],
      [ :delete, api_v1_whiteboard_path(@whiteboard) ],
      [ :delete, api_v1_field_recording_path(@recording) ],
      [ :post, api_v1_device_streams_path, { name: "New" } ],
      [ :patch, api_v1_device_stream_path(@stream.stream_key), { enabled: true } ],
      [ :post, credential_api_v1_device_stream_path(@stream.stream_key) ]
    ]

    requests.each do |verb, path, params|
      # A JSON GET is sent as a POST with X-Http-Method-Override: GET, and
      # Rails writes that header into the hash it was given, which would turn
      # every later POST into a GET. So: plain GETs and a fresh hash each time.
      public_send(verb, path, params: params || {}, headers: @headers.dup, as: (:json unless verb == :get))
      assert_equal verb.to_s.upcase, request.method
      assert_response :not_found, "#{verb.upcase} #{path}: #{response.body.first(200)}"
    end

    assert_equal "Board call", @recording.reload.title
    assert @recording.kept?
    assert_equal "Notes", @file.reload.title
    assert_equal "Tomás", @voice.reload.name
    assert @voice.kept?
    assert_nil @whiteboard.reload.deleted_at
    assert_nil @speaker.reload.field_voice_id
    assert_not @stream.reload.enabled?
    assert_equal 1, DeviceStream.where(subject_user: @user).count
    assert_nil @user.reload.field_you_hint_dismissed_at
  end

  test "device-stream recovery stays open to the subject of a disabled account" do
    get api_v1_device_streams_path, headers: @headers
    assert_response :success
    assert_equal [ @stream.stream_key ], response.parsed_body["device_streams"].map { |s| s["id"] }

    get api_v1_device_stream_path(@stream.stream_key), headers: @headers
    assert_response :success
    assert_not response.parsed_body.dig("device_stream", "manageable")

    delete api_v1_device_stream_path(@stream.stream_key), headers: @headers
    assert_response :no_content
    assert @stream.reload.erased_at
  end

end
