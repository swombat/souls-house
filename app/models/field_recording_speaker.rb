# One diarized speaker in a recording (spec §3, §7). Its name is the name of
# the voice a human linked it to, or "Speaker N". Naming affects this speaker
# only; renaming a voice is the separate act that changes every transcript.
class FieldRecordingSpeaker < ApplicationRecord

  include ObfuscatesId

  NAMING_SOURCES = %w[human confirmed_suggestion confirmed_recognition].freeze

  belongs_to :field_recording
  belongs_to :field_voice, optional: true
  belongs_to :named_by, polymorphic: true, optional: true
  belongs_to :suggested_voice, class_name: "FieldVoice", optional: true

  SUGGESTION_FIELDS = { suggested_voice: nil, suggested_name: nil, suggestion_quote: nil,
                        suggestion_quote_ms: nil, suggestion_source: nil, suggested_at: nil,
                        suggestion_generation: nil }.freeze

  validates :label, presence: true
  validates :naming_source, inclusion: { in: NAMING_SOURCES }, allow_nil: true

  scope :in_order, -> { order(:position) }

  def default_name = "Speaker #{position + 1}"
  def display_name = field_voice&.kept? ? field_voice.name : default_name

  # A human names this speaker. Under the recording lock; the transcript text
  # is re-rendered in the same transaction.
  def name_as!(voice, by:, source: "human")
    raise ArgumentError, "voice from another account" unless voice.account_id == field_recording.account_id

    field_recording.with_lock do
      raise ActiveRecord::RecordNotFound unless field_recording.kept? && field_recording.ready?

      update!(field_voice: voice, naming_source: source, named_by: by, named_at: Time.current,
        decision_generation: decision_generation + 1, **SUGGESTION_FIELDS)
      field_recording.update!(transcript_text: field_recording.render_transcript_text)
    end
  end

  def suggestion? = suggested_name.present? && !field_voice&.kept?

  # The chip the person saw is still the live suggestion: same generation, no
  # decision since, still unnamed. Checked under the recording lock.
  def suggestion_current?(shown_generation)
    reload
    suggestion? && suggestion_generation == decision_generation && shown_generation.to_s == decision_generation.to_s
  end

  # Returns false when the chip was out of date (and changes nothing).
  def dismiss_suggestion!(shown_generation)
    field_recording.with_lock do
      next false unless suggestion_current?(shown_generation)

      update!(decision_generation: decision_generation + 1, **SUGGESTION_FIELDS)
      true
    end
  end

  def unname!
    field_recording.with_lock do
      # Same guard as name_as!: a request that found the recording before a
      # discard must not change it after waiting for the lock.
      raise ActiveRecord::RecordNotFound unless field_recording.kept? && field_recording.ready?

      update!(field_voice: nil, naming_source: nil, named_by: nil, named_at: nil,
        decision_generation: decision_generation + 1, **SUGGESTION_FIELDS)
      field_recording.update!(transcript_text: field_recording.render_transcript_text)
    end
  end

end
