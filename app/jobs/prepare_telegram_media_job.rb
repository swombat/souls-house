class PrepareTelegramMediaJob < ApplicationJob

  class WakeEnqueueError < StandardError; end

  self.log_arguments = false

  retry_on TelegramNotifiable::TelegramMediaTransientError, wait: :polynomially_longer, attempts: 3 do |job, _error|
    telegram_message = job.arguments.first
    job.send(:fail_media!, telegram_message, "temporary_download_failure") if telegram_message&.persisted?
  end
  retry_on WakeEnqueueError, wait: 30.seconds, attempts: 10

  queue_as :default

  def perform(telegram_message, file_id, telegram_metadata = {})
    telegram_message.reload
    return if telegram_message.media_status == "ready" && telegram_message.wake_enqueued_at.present?
    return enqueue_wake!(telegram_message) if telegram_message.media_status == "ready"

    agent = telegram_message.telegram_subscription.agent
    file_info = agent.telegram_file_info(file_id)
    downloaded = agent.telegram_download_file(
      file_info.fetch("file_path"),
      max_bytes: TelegramMessage.media_limit_for(telegram_message.media_kind)
    )

    prepare_downloaded_media(telegram_message, downloaded.tempfile, telegram_metadata)
    telegram_message.update!(media_status: "ready", media_error: nil)
    telegram_message.rebuild_text!
    enqueue_wake!(telegram_message)
  rescue TelegramNotifiable::TelegramMediaPermanentError => e
    fail_media!(telegram_message, error_category(e))
  ensure
    downloaded&.tempfile&.close!
  end

  private

  def prepare_downloaded_media(telegram_message, tempfile, telegram_metadata)
    content_type = Marcel::MimeType.for(tempfile, name: "telegram-upload")
    validate_content_type!(telegram_message.media_kind, content_type)
    extension = extension_for(content_type)
    filename = "telegram-#{telegram_message.media_kind}-#{telegram_message.id}.#{extension}"

    tempfile.rewind
    telegram_message.media.attach(io: tempfile, filename: filename, content_type: content_type)
    telegram_message.update!(
      media_metadata: telegram_message.media_metadata.merge(telegram_metadata).merge(
        "content_type" => content_type,
        "byte_size" => tempfile.size
      )
    )

    prepare_voice(telegram_message, tempfile, filename, content_type) if telegram_message.voice?
    prepare_video(telegram_message, tempfile) if telegram_message.video?
  end

  def prepare_voice(telegram_message, tempfile, filename, content_type)
    telegram_message.update!(
      transcription: transcribe(tempfile, filename, content_type),
      media_metadata: telegram_message.media_metadata.except("transcription_status")
    )
  rescue ElevenLabsStt::Error => e
    Rails.logger.warn("[TelegramMedia] voice transcription failed for message #{telegram_message.id}: #{e.class}")
    telegram_message.update!(
      transcription: nil,
      media_metadata: telegram_message.media_metadata.merge("transcription_status" => "failed")
    )
  end

  def prepare_video(telegram_message, tempfile)
    preview = TelegramVideoPreview.new(tempfile.path, telegram_message.id).call
    metadata = telegram_message.media_metadata.merge(preview.metadata)

    if preview.audio
      begin
        transcription = transcribe(
          preview.audio,
          "telegram-video-audio-#{telegram_message.id}.wav",
          "audio/wav"
        )
        metadata.delete("transcription_status")
        telegram_message.transcription = transcription
      rescue ElevenLabsStt::Error => e
        Rails.logger.warn("[TelegramMedia] video transcription failed for message #{telegram_message.id}: #{e.class}")
        metadata["transcription_status"] = "failed"
      end
    end

    telegram_message.preview_frames.purge if telegram_message.preview_frames.attached?
    if preview.frames.any?
      telegram_message.preview_frames.attach(preview.frames.map.with_index do |frame, index|
        {
          io: frame.fetch(:tempfile),
          filename: "telegram-frame-#{telegram_message.id}-#{index + 1}.jpg",
          content_type: "image/jpeg"
        }
      end)
      metadata["preview_timestamps"] = preview.frames.map { |frame| frame.fetch(:timestamp_seconds) }
    end

    telegram_message.update!(transcription: telegram_message.transcription, media_metadata: metadata)
  rescue TelegramVideoPreview::Error => e
    Rails.logger.warn("[TelegramMedia] video preview failed for message #{telegram_message.id}: #{e.class}")
    telegram_message.update!(
      media_metadata: telegram_message.media_metadata.merge("preview_status" => "failed")
    )
  ensure
    preview&.close
  end

  def transcribe(io, filename, content_type)
    io.rewind
    ElevenLabsStt.transcribe(Upload.new(io, filename, content_type))
  end

  def validate_content_type!(kind, content_type)
    allowed = {
      "photo" => %w[image/jpeg image/png image/webp image/gif],
      "voice" => %w[audio/ogg audio/opus audio/mpeg audio/mp4 audio/x-m4a audio/wav audio/x-wav audio/webm video/webm],
      "video" => %w[video/mp4 video/quicktime video/webm]
    }.fetch(kind)

    raise TelegramNotifiable::TelegramMediaInvalid, "Unexpected media type" unless allowed.include?(content_type)
  end

  def extension_for(content_type)
    {
      "image/jpeg" => "jpg",
      "image/png" => "png",
      "image/webp" => "webp",
      "image/gif" => "gif",
      "audio/ogg" => "ogg",
      "audio/opus" => "opus",
      "audio/mpeg" => "mp3",
      "audio/mp4" => "m4a",
      "audio/x-m4a" => "m4a",
      "audio/wav" => "wav",
      "audio/x-wav" => "wav",
      "audio/webm" => "webm",
      "video/webm" => "webm",
      "video/mp4" => "mp4",
      "video/quicktime" => "mov"
    }.fetch(content_type)
  end

  def enqueue_wake!(telegram_message)
    job = TelegramAgentTriggerJob.perform_later(telegram_message.telegram_subscription, telegram_message)
    raise WakeEnqueueError, "Could not enqueue the Resident wake" unless job.successfully_enqueued?

    telegram_message.update!(wake_enqueued_at: Time.current)
  end

  def fail_media!(telegram_message, category)
    return unless telegram_message&.persisted?

    telegram_message.update!(media_status: "failed", media_error: category)
    telegram_message.rebuild_text!
    notify_media_failure(telegram_message, category)
    enqueue_follow_up_wake(telegram_message)
  end

  def notify_media_failure(telegram_message, category)
    subscription = telegram_message.telegram_subscription
    subscription.agent.telegram_send_message(
      subscription.telegram_chat_id,
      failure_message(telegram_message.media_kind, category)
    )
  rescue TelegramNotifiable::TelegramError => e
    Rails.logger.warn("[TelegramMedia] could not notify sender for message #{telegram_message.id}: #{e.class}")
  end

  def enqueue_follow_up_wake(telegram_message)
    subscription = telegram_message.telegram_subscription
    return unless subscription.telegram_messages.where(role: "user").where("id > ?", telegram_message.id).exists?

    TelegramAgentTriggerJob.perform_later(subscription, telegram_message)
  end

  def error_category(error)
    error.is_a?(TelegramNotifiable::TelegramMediaTooLarge) ? "too_large" : "invalid_media"
  end

  def failure_message(kind, category)
    return "That video is over souls.house's 20 MB Telegram limit. Please trim or compress it and send it again." if category == "too_large" && kind == "video"
    return "That #{kind} is over souls.house's 20 MB Telegram limit. Please send a smaller file." if category == "too_large"
    return "souls.house couldn't download that file after several attempts. Please try sending it again." if category == "temporary_download_failure"

    "souls.house couldn't read that #{kind}. Please try a different file."
  end

  Upload = Struct.new(:io, :original_filename, :content_type) do
    delegate :read, :rewind, :path, :size, to: :io
  end

end
