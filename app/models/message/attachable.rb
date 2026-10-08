module Message::Attachable

  extend ActiveSupport::Concern

  MAX_FILE_SIZE = 50.megabytes

  included do
    has_many_attached :attachments do |attachable|
      attachable.variant :thumb,
        resize_to_limit: [ 200, 200 ],
        format: :jpeg,
        saver: { quality: 70, strip: true }

      attachable.variant :preview,
        resize_to_limit: [ 1200, 1200 ],
        format: :jpeg,
        saver: { quality: 80, strip: true }
    end

    has_one_attached :audio_recording
    has_one_attached :voice_audio

    validate :acceptable_files
  end

  def files_json
    return [] unless attachments.attached?

    url_helpers = Rails.application.routes.url_helpers

    attachments.map do |file|
      file_data = {
        id: file.id,
        filename: file.filename.to_s,
        content_type: file.content_type,
        byte_size: file.byte_size
      }

      begin
        file_data[:url] = url_helpers.rails_blob_url(file, only_path: true, disposition: :attachment)

        if file.variable?
          file_data[:thumb_url] = url_helpers.rails_representation_url(file.variant(:thumb), only_path: true)
          file_data[:preview_url] = url_helpers.rails_representation_url(file.variant(:preview), only_path: true)
        end
      rescue ArgumentError
        file_data[:url] = "/files/#{file.id}"
      end

      file_data
    end
  end

  def audio_url = blob_url_for(audio_recording)
  def voice_audio_url = blob_url_for(voice_audio)

  # Files the speaker attached, then the voice recording behind a dictated
  # message. The recording is the audio the composer transcribed; the message
  # content is that transcript after the speaker's edits, so a resident that
  # can listen can check what was actually said.
  def attachments_for_api
    files = attachments.map { |attachment| attachment_for_api(attachment, kind: "file") }
    files << attachment_for_api(audio_recording_attachment, kind: "voice_recording") if audio_recording.attached?
    files
  end

  # The attachment row a resident may download through this message: one of
  # its files or its voice recording. Nil when the id belongs to neither.
  def api_downloadable_attachment(id)
    attachments_attachments.find_by(id: id) ||
      (audio_recording_attachment if audio_recording.attached? && audio_recording_attachment.id.to_s == id.to_s)
  end

  private

  def attachment_for_api(attachment, kind:)
    {
      id: attachment.id.to_s,
      kind: kind,
      filename: attachment.filename.to_s,
      content_type: attachment.content_type,
      byte_size: attachment.byte_size,
      download_path: Rails.application.routes.url_helpers.api_v1_conversation_message_attachment_path(
        chat.to_param,
        to_param,
        attachment.id
      )
    }
  end

  def blob_url_for(attachment)
    return unless attachment.attached?
    Rails.application.routes.url_helpers.rails_blob_url(attachment, only_path: true)
  rescue ArgumentError
    nil
  end

  def acceptable_files
    return unless attachments.attached?

    attachments.each do |file|
      if file.byte_size > MAX_FILE_SIZE
        errors.add(:attachments, "#{file.filename}: must be less than #{MAX_FILE_SIZE / 1.megabyte}MB")
      end
    end
  end

end
