require "test_helper"

class Api::V1::Companion::PocketSubmissionsControllerTest < ActionDispatch::IntegrationTest

  # Kept at the ElevenLabs seam, as Chats::TranscriptionsControllerTest is.

  setup do
    @agent = agents(:research_assistant)
    @account = @agent.account
    @owner = users(:user_1)
    @device, @credential = enroll(kind: "pocket")
  end

  def enroll(kind:)
    if kind == "pocket"
      pairing, _code, secret = CompanionPairing.open!(name: "The stone", device_request_id: "stone-#{SecureRandom.hex(4)}",
        volumes: nil, kind: "pocket", capabilities: %w[mic camera])
      pairing.approve!(account: @account, user: @owner, agents: [ @agent ], accesses: {})
    else
      pairing, _code, secret = CompanionPairing.open!(name: "A Mac", device_request_id: "mac-#{SecureRandom.hex(4)}",
        volumes: [ { "volume" => "v", "label" => "V", "access" => "read" } ])
      pairing.approve!(account: @account, user: @owner, agents: [ @agent ], accesses: { "v" => "read" })
    end
    _state, payload = CompanionPairing.claim(pairing.to_param, secret)
    device, credential, = CompanionEnrollmentGrant.enroll!(payload["enrollment_token"], payload["device_request_id"])
    [ device, credential ]
  end

  def post_clip(credential: @credential, request_id: "r1", kind: "voice",
    file: fixture_file_upload("test_audio.webm", "audio/webm"), heard: "is it raining in Geneva")
    ElevenLabsStt.stub(:transcribe, heard) do
      TranscriptionCharge.stub(:admit!, true) do
        post "/api/v1/companion/pocket/submissions", params: { request_id: request_id, kind: kind, file: file },
          headers: { "Authorization" => "Bearer #{credential}" }
      end
    end
  end

  test "no credential, or a computer's, is refused" do
    post_clip(credential: "shcd_nope")
    assert_response :unauthorized
    _mac, mac_credential = enroll(kind: "computer")
    post_clip(credential: mac_credential)
    assert_response :forbidden
    assert_equal "not_pocket", response.parsed_body["code"]
  end

  test "the microphone off refuses the clip before it is transcribed or written" do
    called = false
    ElevenLabsStt.stub(:transcribe, ->(*, **) { called = true }) do
      assert_no_difference -> { Message.count } do
        post "/api/v1/companion/pocket/submissions",
          params: { request_id: "r1", kind: "voice", file: fixture_file_upload("test_audio.webm", "audio/webm") },
          headers: { "Authorization" => "Bearer #{@credential}" }
      end
    end
    assert_response :forbidden
    assert_equal "consent_off", response.parsed_body["code"]
    assert_not called
  end

  test "a clip becomes one message from the stone, and its retry is the same message" do
    @device.change_capture!(capability: "mic", enabled: true, actor: @owner)
    assert_difference -> { @device.chat.messages.count }, 1 do
      post_clip
      assert_response :created
      post_clip
      assert_response :ok
    end
    message = @device.chat.messages.order(:id).last
    assert_equal "is it raining in Geneva", message.content
    assert_equal @device, message.companion_device
    assert message.audio_recording.attached?
    assert_equal message.to_param, response.parsed_body["submission_id"]
  end

  test "a second clip while the first awaits its reply is posted; past the cap it is refused" do
    @device.change_capture!(capability: "mic", enabled: true, actor: @owner)
    cap = CompanionDevice::Pocket::MAX_QUEUED_CLIPS
    assert_difference -> { @device.chat.messages.count }, cap do
      cap.times do |i|
        post_clip(request_id: "r#{i}", heard: "clip #{i}")
        assert_response :created
      end
    end
    post_clip(request_id: "one-too-many", heard: "and another")
    assert_response :conflict
    assert_equal "awaiting_reply", response.parsed_body["code"]
  end

  test "the same words twice in a row are refused, not posted, and leave no stored clip" do
    @device.change_capture!(capability: "mic", enabled: true, actor: @owner)
    post_clip(request_id: "r1", heard: "hello?")
    assert_response :created
    assert_no_difference [ "Message.count", "ActiveStorage::Blob.count" ] do
      post_clip(request_id: "r2", heard: "hello?")
    end
    assert_response :conflict
    assert_equal "same_as_last", response.parsed_body["code"]
  end

  test "a photo needs the camera switch and JPEG bytes, whatever the label says" do
    @device.change_capture!(capability: "mic", enabled: true, actor: @owner)
    post_clip(kind: "photo", file: fixture_file_upload("test_photo.jpg", "image/jpeg"))
    assert_equal "consent_off", response.parsed_body["code"]
    @device.change_capture!(capability: "camera", enabled: true, actor: @owner)
    post_clip(kind: "photo", file: fixture_file_upload("test_image.png", "image/jpeg"))
    assert_response :unsupported_media_type
    post_clip(kind: "photo", file: fixture_file_upload("test_photo.jpg", "application/octet-stream"))
    assert_response :created
    assert @device.chat.messages.order(:id).last.attachments.attached?
  end

  # A 61-second 8 kHz mono WAV, about 490 kB: under the size limit, over the time limit.
  def long_wav
    rate = 8_000
    data = "\x80".b * (rate * 61)
    header = [ "RIFF", 36 + data.bytesize, "WAVE", "fmt ", 16, 1, 1, rate, rate, 1, 8, "data", data.bytesize ].pack("a4Va4a4VvvVVvva4V")
    file = Tempfile.new([ "long", ".wav" ])
    file.binmode
    file.write(header + data)
    file.flush
    Rack::Test::UploadedFile.new(file.path, "audio/wav", true)
  end

  test "a clip over 60 seconds is refused before it is stored or transcribed" do
    @device.change_capture!(capability: "mic", enabled: true, actor: @owner)
    assert_no_difference -> { ActiveStorage::Blob.count } do
      post_clip(file: long_wav)
    end
    assert_response :content_too_large
    assert_equal "too_long", response.parsed_body["code"]
  end

  test "capture switched off between transcription and commit leaves no message, no wake and no stored clip" do
    @device.change_capture!(capability: "mic", enabled: true, actor: @owner)
    switch_off = lambda do |*, **|
      CompanionDevice.find(@device.id).change_capture!(capability: "mic", enabled: false, actor: @owner)
      "said while the switch went off"
    end
    assert_no_difference [ -> { Message.count }, -> { MessageDispatch.count }, -> { ActiveStorage::Blob.count } ] do
      ElevenLabsStt.stub(:transcribe, switch_off) do
        TranscriptionCharge.stub(:admit!, true) do
          post "/api/v1/companion/pocket/submissions",
            params: { request_id: "r1", kind: "voice", file: fixture_file_upload("test_audio.webm", "audio/webm") },
            headers: { "Authorization" => "Bearer #{@credential}" }
        end
      end
    end
    assert_response :forbidden
    assert_equal "consent_off", response.parsed_body["code"]
  end

  test "a clip with no speech is refused without a message, so the next clip goes straight through" do
    @device.change_capture!(capability: "mic", enabled: true, actor: @owner)
    assert_no_difference [ -> { Message.count }, -> { ActiveStorage::Blob.count } ] do
      ElevenLabsStt.stub(:transcribe, "  ") do
        TranscriptionCharge.stub(:admit!, true) do
          post "/api/v1/companion/pocket/submissions",
            params: { request_id: "silent", kind: "voice", file: fixture_file_upload("test_audio.webm", "audio/webm") },
            headers: { "Authorization" => "Bearer #{@credential}" }
        end
      end
    end
    assert_response :unprocessable_entity
    assert_equal "no_speech", response.parsed_body["code"]
    assert_nil @device.reload.pocket_open_message_id

    post_clip(request_id: "spoken")
    assert_response :created
  end

  test "a transcription failure leaves no stored clip" do
    @device.change_capture!(capability: "mic", enabled: true, actor: @owner)
    assert_no_difference [ -> { Message.count }, -> { ActiveStorage::Blob.count } ] do
      ElevenLabsStt.stub(:transcribe, ->(*, **) { raise ElevenLabsStt::Error, "down" }) do
        TranscriptionCharge.stub(:admit!, true) do
          post "/api/v1/companion/pocket/submissions",
            params: { request_id: "r1", kind: "voice", file: fixture_file_upload("test_audio.webm", "audio/webm") },
            headers: { "Authorization" => "Bearer #{@credential}" }
        end
      end
    end
    assert_response :service_unavailable
  end

  test "a paused stone is refused" do
    @device.change_capture!(capability: "mic", enabled: true, actor: @owner)
    @device.apply_control!("pause")
    post_clip
    assert_response :unauthorized
  end

end
