require "stringio"
require "date"
require "time"

module FieldVoiceSamples
  module Uploads

    METADATA = %i[source_identifier source_sha256 source_session start_ms end_ms recorded_at idempotency_key field_recording_id].freeze
    MAX_RETRY_ALIASES = 100
    Result = Data.define(:sample, :deduplicated)
    module_function

    def create!(voice:, by:, file:, metadata: {})
      create_with_receipt!(voice:, by:, file:, metadata:).sample
    end

    def create_with_receipt!(voice:, by:, file:, metadata: {})
      bytes, speech_ms = Wav.read!(file)
      attributes = normalize_metadata(metadata)
      if attributes[:start_ms] && (attributes[:end_ms] - attributes[:start_ms] - speech_ms).abs > 1
        raise Invalid, "The source interval must match the uploaded WAV duration."
      end
      content_sha256 = Digest::SHA256.hexdigest(bytes)
      fingerprint = Digest::SHA256.hexdigest(JSON.generate(
        [ voice.id, content_sha256, attributes.except(:idempotency_key).sort_by { |key, _| key.to_s } ]
      ))
      FieldVoiceprints::Locks.with(account: voice.account, voices: [ voice ]) do |account, _recording, voices|
        live_voice = voices.first
        raise Conflict, "This voice is no longer available." unless live_voice&.kept?

        key = attributes[:idempotency_key]
        previous = account_samples(account).where("idempotency_key = :key OR idempotency_receipts ? :key", key:).first if key
        if previous
          expected = previous.idempotency_key == key ? previous.request_digest : previous.idempotency_receipts[key]
          raise Conflict, "This idempotency key was used for a different upload." unless expected == fingerprint
          next Result.new(sample: previous, deduplicated: "retry")
        end
        duplicates = duplicates(account, content_sha256, attributes)
        existing = duplicates.first
        if existing
          raise Conflict, "This audio already belongs to another voice." if duplicates.any? { |row| row.field_voice_id != live_voice.id }
          if key
            raise Conflict, "This sample has too many retry keys. Use an existing key." if
              existing.idempotency_receipts.size >= MAX_RETRY_ALIASES
            existing.update_columns(idempotency_receipts: existing.idempotency_receipts.merge(key => fingerprint))
          end
          next Result.new(sample: existing, deduplicated: existing.content_sha256 == content_sha256 ? "identical" : "overlap")
        end
        ensure_pending_capacity!(live_voice)
        if attributes[:field_recording_id]
          account.field_recordings.kept.find_by!(id: attributes[:field_recording_id])
        end
        session = attributes[:source_session] || attributes[:source_sha256] || attributes[:source_identifier] || content_sha256
        provenance = attributes.slice(:source_sha256, :source_identifier, :field_recording_id)
        if provenance.any?
          group = attributes[:field_recording_id] ?
            "account:#{account.id}:recording:#{attributes[:field_recording_id]}" : "account:#{account.id}:source:#{session}"
          scope = account_samples(account).not_removed
          originals = provenance.reduce(scope.none) { |rows, (key, value)| rows.or(scope.where(key => value)) }
          if originals.any? { |row| row.source_group_key != group }
            raise Conflict, "This original source already has a different session group. Reuse its canonical group."
          end
        end

        sample = FieldVoiceSample.new(attributes.merge(
          account:, field_voice: live_voice, content_sha256:, speech_ms:, request_digest: fingerprint,
          source_session: session,
          label_origin: human?(by) ? "human" : "machine", uploaded_by: human?(by) ? by : nil,
          eligible: false, learning_status: "pending"
        ))
        sample.audio.attach(io: StringIO.new(bytes), filename: "voice-sample.wav", content_type: "audio/wav")
        sample.save!
        sample.update!(source_digest: source_digest(sample))
        Result.new(sample:, deduplicated: nil)
      end
    rescue ActiveRecord::RecordNotFound
      raise Invalid, "Choose a recording in this account."
    end

    def learn!(sample, client: FieldVoiceprints::VoiceEmbeddings)
      sample = FieldVoiceSample.find_by(id: sample.id)
      return :gone unless sample
      raise Invalid, "This operation requires an uploaded sample." unless sample.standalone?

      snapshot = learning_snapshot(sample)
      return :stale unless learnable?(sample, snapshot)
      bytes = sample.audio.download
      return :stale unless Digest::SHA256.hexdigest(bytes) == sample.content_sha256

      result = client.embed(bytes)
      unless FieldVoiceprints::VoiceEmbeddings.valid_vector?(result.embedding) &&
          FieldVoiceprints::VoiceEmbeddings.valid_profile?(result.profile)
        raise Invalid, "The voice service returned an invalid sample."
      end
      with_sample_lock(sample) do |live|
        unless learnable?(live, snapshot)
          if snapshot == learning_snapshot(live) && !live.account.recognise_voices?
            live.update!(learning_status: "pending")
          end
          next :stale
        end

        live.vector = result.embedding
        live.update!(profile: result.profile, learning_status: "learned", learning_error: nil)
        # A replacement embedding never silently changes a confirmed print.
        # Only unconfirmed standalone samples may be learned.
        :learned
      end
    rescue ActiveStorage::FileNotFoundError
      mark_error(sample, snapshot, "The retained audio is unavailable.")
      :gone
    rescue FieldVoiceprints::VoiceEmbeddings::Unavailable
      mark_error(sample, snapshot, "The voice service is unavailable. Please try again.")
      raise
    rescue Invalid
      mark_error(sample, snapshot, "The voice service could not learn this sample.")
      raise
    end

    def source_digest(sample)
      blob = sample.audio.blob
      Digest::SHA256.hexdigest(JSON.generate([
        sample.account_id, sample.field_voice_id, sample.content_sha256, sample.source_identifier,
        sample.source_sha256, sample.source_session, sample.start_ms, sample.end_ms,
        sample.recorded_at&.utc&.iso8601(6), sample.field_recording_id, blob&.id, blob&.key, blob&.checksum
      ]))
    end

    def ensure_pending_capacity!(voice, except: nil)
      FieldVoiceprints::Limits.pending!(voice, except_sample: except)
    end

    def with_sample_lock(sample)
      # Take the account lock before discovering the current attribution:
      # reattribution may have moved the row since the caller loaded it.
      sample.account.with_lock do
        live = FieldVoiceSample.find_by(id: sample.id)
        next :gone unless live
        live.field_recording&.lock!
        live.field_voice.lock!
        live.reload
        yield live
      end
    end

    def human?(by) = by.is_a?(User) && by.persisted?

    def account_samples(account) = FieldVoiceSample.where(account:, field_recording_speaker_id: nil)

    def duplicates(account, content_sha256, attributes)
      scope = account_samples(account).not_removed
      matches = scope.where(content_sha256:)
      if attributes[:start_ms]
        %i[source_sha256 source_identifier field_recording_id].each do |key|
          next unless attributes[key]
          overlaps = scope.where(key => attributes[key])
            .where("start_ms < ? AND end_ms > ?", attributes[:end_ms], attributes[:start_ms])
          matches = matches.or(overlaps)
        end
      end
      matches.order(:id).to_a
    end

    def normalize_metadata(metadata)
      data = metadata.to_h.symbolize_keys.slice(*METADATA).compact
      %i[source_identifier source_session idempotency_key].each do |key|
        next unless data.key?(key)
        raise Invalid, "Source identifiers must be nonempty strings of at most 255 characters." unless
          data[key].is_a?(String) && data[key].present? && data[key].length <= 255
      end
      if data.key?(:source_sha256)
        raise Invalid, "Provide the original source SHA-256." unless data[:source_sha256].is_a?(String) &&
          data[:source_sha256].match?(/\A[0-9a-fA-F]{64}\z/)
        data[:source_sha256] = data[:source_sha256].downcase
      end
      if data.key?(:start_ms) || data.key?(:end_ms)
        %i[start_ms end_ms].each do |key|
          data[key] = Integer(data[key].to_s, 10, exception: false)
        end
        raise Invalid, "Provide both source interval endpoints in milliseconds." unless
          data[:start_ms] && data[:end_ms] && data[:start_ms] >= 0 && data[:end_ms] > data[:start_ms] &&
          data[:end_ms] <= 2_147_483_647
        raise Invalid, "A source interval requires an original source identifier or SHA-256." unless
          data[:source_identifier] || data[:source_sha256] || data[:field_recording_id]
      end
      if data.key?(:recorded_at)
        value = data[:recorded_at]
        raise Invalid, "Provide an ISO 8601 date or a timestamp with an explicit time zone." unless value.is_a?(String)
        if value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          date = Date.iso8601(value)
          data[:recorded_at] = Time.utc(date.year, date.month, date.day).iso8601(6)
        else
          raise Invalid, "Provide an ISO 8601 date or a timestamp with an explicit time zone." unless
            value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/)
          # Date validates the calendar day too: Time.iso8601 alone can
          # normalize impossible dates such as February 30 into March.
          Date.iso8601(value.byteslice(0, 10))
          data[:recorded_at] = Time.iso8601(value).utc.iso8601(6)
        end
      end
      if data.key?(:field_recording_id)
        data[:field_recording_id] = Integer(data[:field_recording_id].to_s, 10, exception: false)
        raise Invalid, "Choose a recording in this account." unless data[:field_recording_id]
      end
      data
    rescue ArgumentError
      raise Invalid, "Provide a valid ISO 8601 recording time."
    end

    def learning_snapshot(sample)
      [ sample.field_voice_id, sample.review_generation, sample.source_digest, sample.content_sha256,
        sample.field_voice.learning_generation, sample.audio.blob_id ]
    end

    def learnable?(sample, snapshot)
      snapshot == learning_snapshot(sample) && sample.removed_at.nil? &&
        !sample.excluded? &&
        sample.account.recognise_voices? && sample.field_voice.kept? && sample.field_voice.remember? && sample.source_current? &&
        sample.confirmed_digest.nil? && (!sample.field_recording || sample.field_recording.kept?)
    end

    def mark_error(sample, snapshot, message)
      return unless sample && snapshot
      with_sample_lock(sample) do |live|
        live.update!(learning_status: "error", learning_error: message) if learnable?(live, snapshot)
      end
    end

  end
end
