# One diarized speaker in a recording (spec §3, §7). Its name is the name of
# the voice a human linked it to, or "Speaker N". Naming affects this speaker
# only; renaming a voice is the separate act that changes every transcript.
class FieldRecordingSpeaker < ApplicationRecord

  include ObfuscatesId

  NAMING_SOURCES = %w[human confirmed_suggestion confirmed_recognition].freeze

  belongs_to :field_recording
  belongs_to :field_voice, optional: true
  belongs_to :named_by, polymorphic: true, optional: true

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

      update!(field_voice: voice, naming_source: source, named_by: by, named_at: Time.current)
      field_recording.update!(transcript_text: field_recording.render_transcript_text)
    end
  end

  def unname!
    field_recording.with_lock do
      update!(field_voice: nil, naming_source: nil, named_by: nil, named_at: nil)
      field_recording.update!(transcript_text: field_recording.render_transcript_text)
    end
  end

end
