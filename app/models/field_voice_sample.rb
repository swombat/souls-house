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

  def serializable_hash(*)
    raise NotImplementedError, "voice samples are never serialised"
  end

  def inspect = "#<FieldVoiceSample id: #{id}, field_voice_id: #{field_voice_id}, " \
                "field_recording_speaker_id: #{field_recording_speaker_id}>"

end
