require "json"
require "fileutils"

module TranscriptionEval
  # Writes a self-contained corpus of voice-composed messages for the
  # transcription eval in eval/transcription/.
  #
  # The composer sends audio to Scribe, the speaker edits the returned text,
  # and only the sent text and the audio are stored. So each sample is
  # (audio, what the speaker finally sent), not (audio, raw transcript).
  # The raw transcript is recovered later by re-running the same model.
  #
  # Only messages written by the named speakers are exported. Discarded
  # (deleted) messages are included and flagged: a voice message deleted
  # soon after posting is usually a transcription the speaker gave up on.
  class Exporter

    CONTEXT_MESSAGES = 3
    CONTEXT_CHARS = 600

    attr_reader :out_dir, :emails, :since, :limit

    def initialize(out_dir:, emails:, since: nil, limit: nil)
      @out_dir = Pathname(out_dir)
      @emails = Array(emails).map { |e| e.to_s.strip.downcase }.reject(&:empty?)
      raise ArgumentError, "at least one speaker email is required" if @emails.empty?

      @since = since
      @limit = limit
    end

    def scope
      users = User.where("lower(email_address) IN (?)", emails)
      relation = Message.where(user_id: users.select(:id), role: "user")
        .joins(:audio_recording_attachment)
        .includes(:user, audio_recording_attachment: :blob)
        .order(:id)
      relation = relation.where(created_at: since..) if since
      relation = relation.limit(limit) if limit
      relation
    end

    def run
      FileUtils.mkdir_p(out_dir.join("audio"))
      count = 0
      File.open(out_dir.join("manifest.jsonl"), "w") do |manifest|
        # find_each ignores order/limit, so iterate the ordered ids instead.
        scope.pluck(:id).each_slice(100) do |ids|
          Message.where(id: ids).includes(:user, audio_recording_attachment: :blob).order(:id).each do |message|
            row = export_one(message)
            next unless row

            manifest.puts(JSON.generate(row))
            count += 1
          end
        end
      end
      count
    end

    def export_one(message)
      blob = message.audio_recording.blob
      return unless blob

      ext = File.extname(blob.filename.to_s).presence || ".webm"
      sample_id = message.to_param
      File.binwrite(out_dir.join("audio", "#{sample_id}#{ext}"), blob.download)

      {
        sample_id: sample_id,
        speaker: message.user.email_address.downcase,
        created_at: message.created_at.utc.iso8601,
        discarded: message.discarded_at.present?,
        sent_text: message.content.to_s,
        audio_path: "audio/#{sample_id}#{ext}",
        content_type: blob.content_type,
        byte_size: blob.byte_size,
        context: context_for(message)
      }
    end

    private

    def context_for(message)
      Message.where(chat_id: message.chat_id, discarded_at: nil).where(id: ...message.id)
        .order(id: :desc).limit(CONTEXT_MESSAGES)
        .pluck(:role, :content)
        .reverse
        .map { |role, content| { role: role, content: content.to_s.truncate(CONTEXT_CHARS) } }
    end

  end
end
