# A voice's print: the L2-normalised mean of its eligible samples, all made
# with one service profile (spec 2026-10-19 §4). Encrypted at rest
# (non-deterministic), never serialised. Rebuilt from all current samples on
# every change, never added to, so the order samples land in doesn't matter.
#
# A print guesses only when it is validated against recordings it wasn't built
# from (FieldVoiceprints::Validation) and that validation was computed on the
# samples it is built from now (validated_digest == sample_digest).
class FieldVoiceprint < ApplicationRecord

  belongs_to :field_voice
  belongs_to :account

  encrypts :print

  validates :print, :generation, :profile, :sample_digest, presence: true

  after_save :refresh_presentation, if: -> {
    (saved_changes.keys & %w[id field_voice_id generation sample_count recording_count speech_ms validated validated_digest]).any?
  }
  before_destroy { refresh_presentation(destroying: true) }

  def vector = JSON.parse(print)

  # Current only while the voice hasn't moved on (forgotten or rebuilt).
  def current? = generation == field_voice.print_generation

  def active? = validated && validated_digest.present? && validated_digest == sample_digest

  def serializable_hash(*)
    raise NotImplementedError, "voice prints are never serialised"
  end

  def inspect = "#<FieldVoiceprint id: #{id}, field_voice_id: #{field_voice_id}, generation: #{generation}>"

  private

  def refresh_presentation(destroying: false)
    voice_ids = destroying ? [ field_voice_id ] : [ field_voice_id, field_voice_id_before_last_save ].compact.uniq
    FieldVoiceActivity.refresh!(FieldVoice.where(id: voice_ids).distinct.pluck(:account_id))
  end

end
