# A stored voice print (spec §9). Encrypted at rest (non-deterministic), never
# serialised: there is no JSON, prop or API shape that carries one, and asking
# for one raises. Destroyed, not discarded, when forgotten.
class FieldVoiceprint < ApplicationRecord

  belongs_to :field_voice
  belongs_to :account
  belongs_to :sample_recording, class_name: "FieldRecording", optional: true
  belongs_to :consented_by, polymorphic: true, optional: true

  encrypts :print

  validates :print, :generation, :sample_ms, :consented_at, :consent_text_version, presence: true

  # Current only while the voice hasn't moved on (forgotten or replaced).
  def current? = generation == field_voice.print_generation

  def serializable_hash(*)
    raise NotImplementedError, "voice prints are never serialised"
  end

  def inspect = "#<FieldVoiceprint id: #{id}, field_voice_id: #{field_voice_id}, generation: #{generation}>"

end
