# One speaker's clean speech in one recording, embedded by the house's voice
# service (spec 2026-10-19 §4). A voice's print is the mean of its eligible
# samples. The embedding is encrypted at rest and never serialised.
class FieldVoiceSample < ApplicationRecord

  include ObfuscatesId

  belongs_to :account
  belongs_to :field_voice
  belongs_to :field_recording_speaker, optional: true
  belongs_to :field_recording, optional: true
  # The source recording without its transcript columns, for confirmation
  # checks that read only whether it is kept, its account and its audio.
  belongs_to :audio_source_recording, -> { select(:id, :account_id, :discarded_at) },
    class_name: "FieldRecording", foreign_key: :field_recording_id, optional: true
  belongs_to :confirmed_by, class_name: "User", optional: true
  belongs_to :uploaded_by, class_name: "User", optional: true
  has_one_attached :audio

  encrypts :embedding
  encrypts :rollback_embedding

  validates :speech_ms, :label_origin, presence: true
  validates :embedding, :profile, presence: true, unless: :standalone?
  validates :label_origin, inclusion: { in: FieldRecordingSpeaker::NAMING_SOURCES }

  scope :eligible, -> { where(eligible: true) }
  scope :not_removed, -> { where(removed_at: nil) }
  # Everything a confirmation check reads, in a few queries rather than a
  # few per sample (Cohort reads every eligible sample in the account).
  scope :with_confirmation_sources, -> {
    preload(audio_source_recording: { audio_attachment: :blob }, audio_attachment: :blob,
      field_recording_speaker: { audio_source_recording: { audio_attachment: :blob } })
  }

  def standalone? = field_recording_speaker_id.nil?

  def source_group_key
    return "account:#{account_id}:recording:#{field_recording_id}" if field_recording_id
    return "account:#{account_id}:source:#{source_session}" if standalone?

    "account:#{account_id}:recording:#{field_recording_id || field_recording_speaker.field_recording_id}"
  end

  def vector = embedding.present? ? JSON.parse(embedding) : nil

  def vector=(values)
    self.embedding = JSON.generate(values)
  end

  def vector_for(wanted)
    raw = if profile == wanted
      embedding
    elsif rollback_profile == wanted
      rollback_embedding
    end
    values = JSON.parse(raw) if raw.present?
    values if FieldVoiceprints::Profiles.valid_vector?(values, wanted)
  rescue JSON::ParserError
    nil
  end

  # These are the exact persisted montage spans, not a newly selected preview.
  # Legacy samples deliberately have neither spans nor a digest.
  # `preloaded:` reads the source recording's audio through associations the
  # caller has just loaded (with_confirmation_sources) instead of querying it.
  def source_current?(speaker: nil, preloaded: false)
    return false if removed_at.present?

    if standalone?
      recording = preloaded ? audio_source_recording : field_recording
      return removed_at.nil? && content_sha256.present? && audio.attached? &&
        (!recording || (recording.kept? && recording.account_id == account_id)) &&
        source_digest == FieldVoiceSamples::Uploads.source_digest(self)
    end

    return false if source_digest.blank? || !source_segments.is_a?(Array) || source_segments.empty?

    speaker ||= FieldRecordingSpeaker.find_by(id: field_recording_speaker_id)
    speaker.present? && speaker.id == field_recording_speaker_id && speaker.field_voice_id == field_voice_id &&
      source_digest == self.class.source_digest_for(speaker, source_segments, preloaded:)
  end

  def manually_confirmed?(speaker: nil, preloaded: false)
    if standalone?
      return confirmed_digest.present? && confirmed_digest == source_digest &&
        confirmed_by_id.present? && confirmed_at.present? && source_current?(preloaded:)
    end

    return false if source_digest.blank?

    speaker ||= FieldRecordingSpeaker.find_by(id: field_recording_speaker_id)
    speaker.present? && speaker.sample_confirmed_digest == source_digest &&
      speaker.sample_confirmed_by_id.present? && speaker.sample_confirmed_at.present? &&
      source_current?(speaker:, preloaded:)
  end

  # For rows loaded with_confirmation_sources.
  def preloaded_manually_confirmed? =
    manually_confirmed?(speaker: (field_recording_speaker unless standalone?), preloaded: true)

  def review!(digest:, by:, included:, unconfirmed_only: false)
    FieldVoiceSamples::Review.review!(self, digest:, by:, included:, unconfirmed_only:)
  end

  def reattribute!(voice:, digest:, by:, unconfirmed_only: false)
    FieldVoiceSamples::Review.reattribute!(self, voice:, digest:, by:, unconfirmed_only:)
  end

  def remove!(digest:, by:, unconfirmed_only: false)
    FieldVoiceSamples::Review.remove!(self, digest:, by:, unconfirmed_only:)
  end

  # Any listening testimony on record, current or not. Residents manage only
  # samples without it.
  def ever_confirmed? = confirmed_by_id.present? || confirmed_at.present? || confirmed_digest.present?

  def self.source_revision_for(speaker, preloaded: false)
    # Text corrections change no audible byte. Attribution corrections and
    # line moves already advance decision_generation. Read no transcript here.
    blob = if preloaded
      speaker.audio_source_recording&.audio_attachment&.blob
    else
      ActiveStorage::Attachment.includes(:blob).find_by(
        record_type: "FieldRecording", record_id: speaker.field_recording_id, name: "audio")&.blob
    end
    Digest::SHA256.hexdigest(JSON.generate([
      blob&.id, blob&.key, blob&.checksum,
      speaker.id, speaker.field_voice_id, speaker.decision_generation
    ]))
  end

  def self.source_digest_for(speaker, segments, preloaded: false)
    Digest::SHA256.hexdigest(JSON.generate([ source_revision_for(speaker, preloaded:), segments ]))
  end

  def serializable_hash(*)
    raise NotImplementedError, "voice samples are never serialised"
  end

  def inspect = "#<FieldVoiceSample id: #{id}, field_voice_id: #{field_voice_id}, " \
                "field_recording_speaker_id: #{field_recording_speaker_id}>"

end
