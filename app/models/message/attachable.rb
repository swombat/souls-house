module Message::Attachable

  extend ActiveSupport::Concern

  ACCEPTABLE_FILE_TYPES = {
    images: %w[image/png image/jpeg image/jpg image/gif image/webp image/bmp],
    audio: %w[
      audio/mpeg
      audio/wav audio/x-wav audio/vnd.wave
      audio/flac audio/x-flac
      audio/m4a audio/x-m4a audio/mp4
      audio/ogg audio/vorbis audio/opus
      audio/webm
    ],
    video: %w[video/mp4 video/quicktime video/x-msvideo video/webm],
    documents: %w[
      application/pdf
      application/msword
      application/vnd.openxmlformats-officedocument.wordprocessingml.document
      text/plain text/markdown text/csv text/html text/css text/xml
      application/json application/xml
      text/x-python application/x-python
      text/x-ruby application/x-ruby
      application/javascript text/javascript
      application/x-yaml text/yaml text/x-yaml
    ]
  }.freeze

  ACCEPTABLE_EXTENSIONS = %w[
    .md .markdown .txt .csv .json .xml .html .htm .css .js .ts .jsx .tsx
    .py .rb .yaml .yml .toml .ini .log .rst .tex .sh .bash .zsh
    .c .h .cpp .hpp .java .go .rs .swift .kt .scala .r .sql
    .mp3 .wav .flac .m4a .ogg .oga .opus .webm
  ].freeze

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
        file_data[:url] = url_helpers.rails_blob_url(file, only_path: true)

        if file.content_type&.start_with?("image/")
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

  def attachments_for_api
    attachments.map do |attachment|
      {
        id: attachment.id.to_s,
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
  end

  private

  def blob_url_for(attachment)
    return unless attachment.attached?
    Rails.application.routes.url_helpers.rails_blob_url(attachment, only_path: true)
  rescue ArgumentError
    nil
  end

  def acceptable_files
    return unless attachments.attached?

    attachments.each do |file|
      unless acceptable_file_type?(file)
        errors.add(:attachments, "#{file.filename}: file type not supported")
      end

      if file.byte_size > MAX_FILE_SIZE
        errors.add(:attachments, "#{file.filename}: must be less than #{MAX_FILE_SIZE / 1.megabyte}MB")
      end
    end
  end

  def acceptable_file_type?(file)
    return true if ACCEPTABLE_FILE_TYPES.values.flatten.include?(file.content_type)

    extension = File.extname(file.filename.to_s).downcase
    ACCEPTABLE_EXTENSIONS.include?(extension)
  end

end
