# One speaker's clean speech in one recording, embedded by the house's voice
# service (spec 2026-10-19 §4). A voice's print is the mean of its eligible
# samples. The embedding is encrypted at rest and never serialised.
class FieldVoiceSample < ApplicationRecord

  belongs_to :account
  belongs_to :field_voice
  belongs_to :field_recording_speaker

  encrypts :embedding

  validates :embedding, :speech_ms, :profile, :label_origin, presence: true
  validates :label_origin, inclusion: { in: FieldRecordingSpeaker::NAMING_SOURCES }

  scope :eligible, -> { where(eligible: true) }

  def vector = JSON.parse(embedding)

  def vector=(values)
    self.embedding = JSON.generate(values)
  end

  # These are the exact persisted montage spans, not a newly selected preview.
  # Legacy samples deliberately have neither spans nor a digest.
  def source_current?
    return false if source_digest.blank? || !source_segments.is_a?(Array) || source_segments.empty?

    speaker = FieldRecordingSpeaker.find_by(id: field_recording_speaker_id)
    speaker.present? && speaker.field_voice_id == field_voice_id &&
      source_digest == self.class.source_digest_for(speaker, source_segments)
  end

  def manually_confirmed?
    source_current? &&
      FieldRecordingSpeaker.where(id: field_recording_speaker_id, sample_confirmed_digest: source_digest)
        .where.not(sample_confirmed_by_id: nil).where.not(sample_confirmed_at: nil).exists?
  end

  def self.source_revision_for(speaker)
    recording = speaker.field_recording
    blob = recording.audio.blob
    Digest::SHA256.hexdigest(JSON.generate([
      [ blob&.id, blob&.key, blob&.checksum ],
      recording.transcript_words, speaker.decision_generation, speaker.label,
      recording.expected_speakers, recording.speakers.count
    ]))
  end

  def self.source_digest_for(speaker, segments)
    Digest::SHA256.hexdigest(JSON.generate([ source_revision_for(speaker), segments ]))
  end

  def serializable_hash(*)
    raise NotImplementedError, "voice samples are never serialised"
  end

  def inspect = "#<FieldVoiceSample id: #{id}, field_voice_id: #{field_voice_id}, " \
                "field_recording_speaker_id: #{field_recording_speaker_id}>"

end
