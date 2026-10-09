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
  belongs_to :recognised_voice, class_name: "FieldVoice", optional: true
  has_many :enrolments, class_name: "FieldVoiceEnrolment", dependent: :destroy

  SUGGESTION_FIELDS = { suggested_voice: nil, suggested_name: nil, suggestion_quote: nil,
                        suggestion_quote_ms: nil, suggestion_source: nil, suggested_at: nil,
                        suggestion_generation: nil }.freeze
  RECOGNITION_FIELDS = { recognised_voice: nil, recognition_confidence: nil, recognition_print_generation: nil }.freeze

  validates :label, presence: true
  validates :naming_source, inclusion: { in: NAMING_SOURCES }, allow_nil: true

  scope :in_order, -> { order(:position) }

  # A supplied transcript names its speakers in its own words, which a person
  # wrote, so a real name there is shown as it was written. Generic labels
  # ("Speaker A", "speaker_0") read as "Speaker N", like the transcriber's.
  GENERIC_LABEL = /\Aspeaker[\s_-]*[a-z0-9]{1,3}\z/i

  def default_name
    return label if field_recording.supplied? && !label.match?(GENERIC_LABEL)

    "Speaker #{position + 1}"
  end
  # Talk time is measured from word timings; a supplied transcript has none,
  # so it is unknown rather than zero.
  def known_talk_ms = field_recording.supplied? ? nil : talk_ms

  def display_name = field_voice&.kept? ? field_voice.name : default_name

  # A human names this speaker. Every speaker decision (naming, un-naming,
  # confirming or dismissing a suggestion or a guess) takes the one lock order,
  # account → recording → voice, and reloads the speaker under it, so it is
  # serialized with delete-name (which holds the account lock while it gathers
  # and clears every linked recording). The voice must still be kept once
  # locked: a request that resolved it before a delete can't link it after.
  def name_as!(voice, by:, source: "human")
    raise ArgumentError, "voice from another account" unless voice.account_id == field_recording.account_id

    FieldVoiceprints::Locks.with(account: field_recording.account, recording: field_recording, voices: [ voice ]) do |_account, recording, voices|
      raise ActiveRecord::RecordNotFound unless recording.kept? && recording.ready? && voices.first&.kept?

      reload
      update!(field_voice: voices.first, naming_source: source, named_by: by, named_at: Time.current,
        decision_generation: decision_generation + 1, **SUGGESTION_FIELDS, **RECOGNITION_FIELDS)
      recording.update!(transcript_text: recording.render_transcript_text)
    end
  end

  # account → recording, the naming order, for decisions that link no voice.
  def with_decision_locks(&)
    FieldVoiceprints::Locks.with(account: field_recording.account, recording: field_recording) do |_account, recording, _voices|
      yield recording
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
    with_decision_locks do |recording|
      next false unless recording.kept? && recording.ready? && suggestion_current?(shown_generation)

      update!(decision_generation: decision_generation + 1, **SUGGESTION_FIELDS)
      true
    end
  end

  def recognition? = recognised_voice_id.present? && !field_voice&.kept? && recognised_voice&.kept?

  # The guess a chip showed: which voice, from which print, against which
  # decision generation. Confirm and dismiss must send it back unchanged.
  def recognition_token
    return nil unless recognition?

    { voice_id: recognised_voice.to_param, print_generation: recognition_print_generation,
      decision_generation: recognition_decision_generation }
  end

  # A person confirms "Tomás?" (spec §9). Under account → recording → voice
  # locks, with the speaker reloaded: both gates open, the guess still exactly
  # the one the chip showed (same voice, same print generation, no decision
  # since), the voice kept and its print still current. Anything stale is
  # refused and changes nothing. Confirming never builds a print.
  def confirm_recognition!(by:, shown:)
    with_recognition_locks(shown) do |account, voice|
      next false unless FieldVoiceprints.enabled_for?(account) && voice&.kept? &&
                        recognition_print_generation == voice.print_generation &&
                        FieldVoiceprint.where(field_voice: voice, generation: voice.print_generation).exists?

      name_as!(voice, by:, source: "confirmed_recognition")
      true
    end
  end

  # Dismissing is allowed with the gates shut (it only removes a guess), but
  # only for the guess the chip showed.
  def dismiss_recognition!(shown:)
    with_recognition_locks(shown) do
      update!(decision_generation: decision_generation + 1, **RECOGNITION_FIELDS)
      true
    end
  end

  def with_recognition_locks(shown)
    shown = (shown || {}).to_h.symbolize_keys
    voice = FieldVoice.find_by(id: FieldVoice.decode_id(shown[:voice_id].to_s))
    recording = field_recording
    FieldVoiceprints::Locks.with(account: recording.account, recording:, voices: [ voice ].compact) do |account, locked_recording, voices|
      reload
      live_voice = voices.first
      current = locked_recording.kept? && locked_recording.ready? && live_voice && !field_voice&.kept? &&
        recognised_voice_id == live_voice.id &&
        recognition_print_generation.to_s == shown[:print_generation].to_s &&
        recognition_decision_generation.to_s == shown[:decision_generation].to_s &&
        decision_generation.to_s == shown[:decision_generation].to_s
      next false unless current

      yield account, live_voice
    end
  end

  def unname!
    with_decision_locks do |recording|
      # Same guard as name_as!: a request that found the recording before a
      # discard must not change it after waiting for the lock.
      raise ActiveRecord::RecordNotFound unless recording.kept? && recording.ready?

      reload
      update!(field_voice: nil, naming_source: nil, named_by: nil, named_at: nil,
        decision_generation: decision_generation + 1, **SUGGESTION_FIELDS)
      recording.update!(transcript_text: recording.render_transcript_text)
    end
  end

end
