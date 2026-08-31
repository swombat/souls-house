require "test_helper"
require "webmock/minitest"
require "open3"

class PrepareTelegramMediaJobTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(
      runtime: "external",
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid",
      telegram_bot_token: "123:ABC",
      telegram_bot_username: "media_bot"
    )
    @subscription = @agent.telegram_subscriptions.create!(
      user: users(:user_1),
      telegram_chat_id: 444
    )
  end

  test "downloads, validates, and attaches a photo before enqueueing the wake" do
    message = create_media_message("photo")
    stub_telegram_download("photo/file.png", file_fixture("test_image.png").binread)

    assert_enqueued_with(job: TelegramAgentTriggerJob) do
      PrepareTelegramMediaJob.perform_now(message, "photo-file", { "width" => 64, "height" => 64 })
    end

    message.reload
    assert_equal "ready", message.media_status
    assert message.media.attached?
    assert_equal "image/png", message.media.content_type
    assert_equal "[Photo]", message.text
    assert message.wake_enqueued_at.present?
  end

  test "repairs a ready message whose wake was not stamped" do
    message = create_media_message("photo")
    message.update!(media_status: "ready", text: "[Photo]")

    assert_enqueued_with(job: TelegramAgentTriggerJob) do
      PrepareTelegramMediaJob.perform_now(message, "unused")
    end

    assert message.reload.wake_enqueued_at.present?
  end

  test "maps Telegram file-too-big to a permanent size failure without a wake" do
    message = create_media_message("video")
    stub_request(:post, "https://api.telegram.org/bot123:ABC/getFile")
      .to_return(status: 200, body: { ok: false, description: "Bad Request: file is too big" }.to_json)
    stub_request(:post, "https://api.telegram.org/bot123:ABC/sendMessage")
      .to_return(status: 200, body: { ok: true, result: {} }.to_json)

    assert_no_enqueued_jobs only: TelegramAgentTriggerJob do
      PrepareTelegramMediaJob.perform_now(message, "large-video")
    end

    message.reload
    assert_equal "failed", message.media_status
    assert_equal "too_large", message.media_error
  end

  test "a failed media download wakes a later message that was waiting behind it" do
    message = create_media_message("video")
    @subscription.telegram_messages.create!(
      role: "user",
      text: "Did the video arrive?",
      sender_name: "Daniel",
      sent_at: 1.second.from_now
    )
    stub_request(:post, "https://api.telegram.org/bot123:ABC/getFile")
      .to_return(status: 200, body: { ok: false, description: "Bad Request: file is too big" }.to_json)
    stub_request(:post, "https://api.telegram.org/bot123:ABC/sendMessage")
      .to_return(status: 200, body: { ok: true, result: {} }.to_json)

    assert_enqueued_with(job: TelegramAgentTriggerJob, args: [ @subscription, message ]) do
      PrepareTelegramMediaJob.perform_now(message, "large-video")
    end

    assert_equal "failed", message.reload.media_status
  end

  test "voice transcription receives detected filename and content type" do
    message = create_media_message("voice", caption: "Listen")
    stub_telegram_download("voice/file.webm", file_fixture("test_audio.webm").binread)
    received = nil

    ElevenLabsStt.stub :transcribe, ->(upload) {
      received = [ upload.original_filename, upload.content_type ]
      "Machine words"
    } do
      PrepareTelegramMediaJob.perform_now(message, "voice-file")
    end

    message.reload
    assert_equal [ "telegram-voice-#{message.id}.webm", "audio/webm" ], received
    assert_equal "Machine words", message.transcription
    assert_equal "Listen\n\nTranscription: Machine words", message.text
  end

  test "empty successful voice transcription remains absent rather than failed" do
    message = create_media_message("voice")
    stub_telegram_download("voice/file.webm", file_fixture("test_audio.webm").binread)

    ElevenLabsStt.stub :transcribe, nil do
      PrepareTelegramMediaJob.perform_now(message, "voice-file")
    end

    message.reload
    assert_nil message.transcription
    assert_nil message.media_metadata["transcription_status"]
    assert_equal "[Voice message]", message.text
  end

  test "voice transcription failure keeps the original and reaches ready" do
    message = create_media_message("voice")
    stub_telegram_download("voice/file.webm", file_fixture("test_audio.webm").binread)

    ElevenLabsStt.stub :transcribe, ->(*) { raise ElevenLabsStt::Error, "no service" } do
      PrepareTelegramMediaJob.perform_now(message, "voice-file")
    end

    message.reload
    assert_equal "ready", message.media_status
    assert message.media.attached?
    assert_equal "failed", message.media_metadata["transcription_status"]
  end

  test "video retry replaces ordered preview frames instead of appending" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "sample.mp4")
      generate_video(path)
      message = create_media_message("video")
      stub_telegram_download("video/file.mp4", File.binread(path))

      PrepareTelegramMediaJob.perform_now(message, "video-file")
      first_count = message.reload.preview_frames.count
      assert_operator first_count, :>, 0

      message.update!(media_status: "pending", wake_enqueued_at: nil)
      PrepareTelegramMediaJob.perform_now(message, "video-file")

      message.reload
      assert_equal first_count, message.preview_frames.count
      assert_equal message.media_metadata["preview_timestamps"].sort,
        message.media_metadata["preview_timestamps"]
      assert_equal false, message.media_metadata["has_audio"]
    end
  end

  private

  def create_media_message(kind, caption: nil)
    label = { "photo" => "Photo", "voice" => "Voice message", "video" => "Video" }.fetch(kind)
    @subscription.telegram_messages.create!(
      role: "user",
      text: [ caption, "[#{label} — processing]" ].compact.join("\n\n"),
      caption: caption,
      media_kind: kind,
      media_status: "pending",
      sender_name: "Daniel",
      telegram_message_id: SecureRandom.random_number(1_000_000),
      sent_at: Time.current
    )
  end

  def stub_telegram_download(file_path, bytes)
    stub_request(:post, "https://api.telegram.org/bot123:ABC/getFile")
      .to_return(status: 200, body: { ok: true, result: { file_path: file_path } }.to_json)
    stub_request(:get, "https://api.telegram.org/file/bot123:ABC/#{file_path}")
      .to_return(status: 200, body: bytes)
  end

  def generate_video(path)
    _stdout, stderr, status = Open3.capture3(
      "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
      "-f", "lavfi", "-i", "testsrc=size=160x120:rate=2",
      "-t", "1", "-c:v", "mpeg4", path
    )
    assert status.success?, stderr
  end

end
