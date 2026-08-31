class TelegramMessage < ApplicationRecord

  include ObfuscatesId

  MEDIA_KINDS = %w[photo voice video document].freeze
  MEDIA_STATUSES = %w[pending ready failed].freeze
  MEDIA_LIMITS = {
    "photo" => 20.megabytes,
    "voice" => 20.megabytes,
    "video" => 20.megabytes,
    "document" => 50.megabytes
  }.freeze

  belongs_to :telegram_subscription, touch: true

  has_one_attached :media
  has_many_attached :preview_frames

  validates :role, inclusion: { in: %w[user assistant] }
  validates :text, presence: true
  validates :sent_at, presence: true
  validates :media_kind, inclusion: { in: MEDIA_KINDS }, allow_nil: true
  validates :media_status, inclusion: { in: MEDIA_STATUSES }, allow_nil: true

  scope :chronological, -> { order(:sent_at, :id) }

  def self.media_limit_for(kind)
    MEDIA_LIMITS.fetch(kind)
  end

  def media?
    media_kind.present?
  end

  MEDIA_KINDS.each do |kind|
    define_method("#{kind}?") { media_kind == kind }
  end

  def rebuild_text!
    update!(text: normalized_text)
  end

  def normalized_text
    return text unless media?

    pieces = []
    pieces << caption if caption.present?
    pieces << "Transcription: #{transcription}" if transcription.present?
    pieces << media_placeholder if pieces.empty? || media_status != "ready"
    pieces.join("\n\n")
  end

  def transcript_line
    "#{sent_at.iso8601} #{sender_name || role}: #{text}"
  end

  def media_json
    return unless media?

    {
      kind: media_kind,
      status: media_status,
      caption: caption,
      transcription: transcription,
      error: media_error,
      metadata: media_metadata,
      original: original_media_json,
      preview_frames: preview_frames_json
    }.compact
  end

  def transcript_json
    result = {
      id: to_param,
      role: role,
      sender: sender_name,
      telegram_username: sender_username,
      text: text,
      timestamp: sent_at.iso8601
    }
    result[:media] = media_json if media?
    result
  end

  def media_prompt
    return text unless media?

    lines = [
      "Media kind: #{media_kind}",
      "Media status: #{media_status}",
      ("Typed caption: #{caption}" if caption.present?),
      ("Machine transcription: #{transcription}" if transcription.present?),
      ("Transcription status: failed or unavailable" if media_metadata["transcription_status"] == "failed"),
      ("Media metadata: #{media_metadata.to_json}" if media_metadata.present?)
    ].compact

    if media.attached?
      lines << "Original download path: #{original_download_path}"
      lines << download_command(original_download_path, media.filename.to_s)
    end

    if preview_frames.attached?
      lines << "Preview frames:"
      preview_frames_json.each_with_index do |frame, index|
        lines << "- Frame #{index + 1} at #{frame[:timestamp_seconds]}s: #{frame[:download_path]}"
        lines << download_command(frame[:download_path], "telegram-frame-#{id}-#{index + 1}.jpg")
      end
    end

    if photo? || preview_frames.attached?
      lines << "Download the image or preview frames and inspect them with the available image tool. Do not infer their contents from the caption alone."
    end

    lines.join("\n")
  end

  private

  def media_placeholder
    label = { "photo" => "Photo", "voice" => "Voice message", "video" => "Video", "document" => "Document" }.fetch(media_kind)
    return "[#{label} — processing]" if media_status == "pending"
    return "[#{label} could not be received]" if media_status == "failed"

    "[#{label}]"
  end

  def original_media_json
    return unless media.attached?

    {
      filename: media.filename.to_s,
      content_type: media.content_type,
      byte_size: media.byte_size,
      download_path: original_download_path
    }
  end

  def preview_frames_json
    timestamps = Array(media_metadata["preview_timestamps"])

    preview_frames_attachments.each_with_index.map do |attachment, index|
      {
        id: attachment.id,
        timestamp_seconds: timestamps[index],
        filename: attachment.filename.to_s,
        content_type: attachment.content_type,
        byte_size: attachment.byte_size,
        download_path: preview_frame_download_path(attachment)
      }.compact
    end
  end

  def original_download_path
    Rails.application.routes.url_helpers.api_v1_telegram_conversation_message_media_path(
      telegram_subscription,
      self
    )
  end

  def preview_frame_download_path(attachment)
    Rails.application.routes.url_helpers.api_v1_telegram_conversation_message_preview_frame_path(
      telegram_subscription,
      self,
      attachment
    )
  end

  def download_command(path, filename)
    safe_filename = filename.gsub(/[^a-zA-Z0-9_.-]/, "-")
    %(Download: curl -L -H "Authorization: Bearer $SOULSHOUSE_BEARER_TOKEN" "$SOULSHOUSE_APP_URL#{path}" -o "/home/agent/work/#{safe_filename}")
  end

end
