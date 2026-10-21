# One diarized speaker in a recording (spec §3, §7). Its name is the name of
# the voice a human linked it to, or "Speaker N". Naming affects this speaker
# only; renaming a voice is the separate act that changes every transcript.
class FieldRecordingSpeaker < ApplicationRecord

  include ObfuscatesId
  include FieldRecordingSpeakerSampleReview

  # human: a person in the browser or the native app. machine: a write through
  # an API key (scripts, residents, the Mac's voice matcher), whatever the
  # client claims. unknown: a naming made before provenance was recorded
  # (spec 2026-10-19 §5). Only a person's decision may teach a voice print.
  NAMING_SOURCES = %w[human confirmed_suggestion confirmed_recognition machine unknown].freeze
  TRAINING_SOURCES = %w[human confirmed_suggestion confirmed_recognition].freeze
  # Why a person stopped asking for a name: noise (not a person at all) or
  # anonymous (a person whose identity doesn't matter here). Either way the
  # speaker stops waiting; only the reason differs.
  IGNORED_AS = %w[noise anonymous].freeze

  belongs_to :field_recording
  belongs_to :field_voice, optional: true
  belongs_to :named_by, polymorphic: true, optional: true
  belongs_to :ignored_by, polymorphic: true, optional: true
  belongs_to :suggested_voice, class_name: "FieldVoice", optional: true
  belongs_to :recognised_voice, class_name: "FieldVoice", optional: true
  has_many :voice_samples, class_name: "FieldVoiceSample", dependent: :delete_all

  # The speaker's own embedding while nobody has named them, so matching
  # again needs no audio work (FieldVoiceprints::Identification). Encrypted,
  # never serialised, cleared by any decision about the speaker.
  encrypts :probe_embedding
  NO_PROBE = { probe_embedding: nil, probe_profile: nil }.freeze

  def serializable_hash(options = nil)
    options = (options || {}).dup
    options[:except] = Array(options[:except]) + %w[probe_embedding probe_profile]
    super(options)
  end

  SUGGESTION_FIELDS = { suggested_voice: nil, suggested_name: nil, suggestion_quote: nil,
                        suggestion_quote_ms: nil, suggestion_source: nil, suggested_at: nil,
                        suggestion_generation: nil }.freeze
  RECOGNITION_FIELDS = { recognised_voice: nil, recognition_confidence: nil, recognition_print_generation: nil,
                         recognition_cohort: nil, recognition_checked: nil }.freeze
  NOT_IGNORED = { ignored_at: nil, ignored_by: nil }.freeze

  # Fields read by FieldItems.speaker_json (including the displayed decision
  # tokens). Bookkeeping such as decision_generation alone is not a refresh.
  PRESENTATION_FIELDS = %w[
    label position field_voice_id naming_source ignored_at ignored_as
    talk_ms clip_start_ms clip_end_ms
    suggested_name suggestion_quote suggestion_quote_ms suggestion_generation
    recognised_voice_id recognition_confidence recognition_print_generation recognition_decision_generation
    recognition_checked
    sample_excluded sample_review_generation sample_confirmed_digest sample_confirmed_by_id sample_confirmed_at
    sample_learning_status sample_learning_error
  ].freeze

  validates :label, presence: true
  validates :naming_source, inclusion: { in: NAMING_SOURCES }, allow_nil: true
  validates :ignored_as, inclusion: { in: IGNORED_AS }

  scope :in_order, -> { order(:position) }

  after_save :touch_recording_for_presentation_changes
  after_destroy :touch_recording_for_presentation_changes

  # A supplied transcript names its speakers in its own words, which a person
  # wrote, so a real name there is shown as it was written. Generic labels
  # ("Speaker A", "speaker_0") read as "Speaker N", like the transcriber's.
  # ASCII letters only, spelled out rather than /i: Ruby's /i folds Unicode
  # (the Kelvin sign as K, long s as s) and PostgreSQL's ~* under a C locale
  # doesn't, and FieldListing's "Needs you" tab repeats this test in SQL as
  # GENERIC_LABEL_SQL. The two must agree.
  GENERIC_LABEL = /\A[Ss][Pp][Ee][Aa][Kk][Ee][Rr][\s_-]*[A-Za-z0-9]{1,3}\z/
  GENERIC_LABEL_SQL = "^[Ss][Pp][Ee][Aa][Kk][Ee][Rr][[:space:]_-]*[A-Za-z0-9]{1,3}$"

  def default_name
    return label if field_recording.supplied? && !label.match?(GENERIC_LABEL)

    "Speaker #{position + 1}"
  end

  # Talk time is measured from word timings; a supplied transcript has none,
  # so it is unknown rather than zero.
  def known_talk_ms = field_recording.supplied? ? nil : talk_ms

  def display_name = field_voice&.kept? ? field_voice.name : default_name

  # A person's decision that this speaker is this voice: the only kind of
  # label a voice print may learn from. Fails closed on anything else.
  def training_label? = field_voice&.kept? == true && TRAINING_SOURCES.include?(naming_source)

  # The writer cutover (spec 2026-10-19 §11, slice A): namings recorded as
  # "human" before every old writer was gone may have come from an API key, so
  # they become "unknown" too. Only rows named before `before` are touched;
  # pass the time the last old web/jobs process stopped. Never promotes.
  def self.mark_unproven_namings_unknown!(before:)
    where(naming_source: "human").where("named_at IS NULL OR named_at < ?", before).update_all(naming_source: "unknown")
  end

  # Who this speaker is, for grouping: the voice a human linked it to, or this
  # diarized speaker alone. Scribe sometimes hears one person as two speakers;
  # once both are linked to one voice they are one person everywhere they are
  # shown. Never by name equality: only the link counts.
  def identity = field_voice&.kept? ? [ :voice, field_voice_id ] : [ :speaker, label ]

  # Speakers grouped by identity, in order of first appearance.
  def self.grouped(speakers) = speakers.sort_by(&:position).group_by(&:identity).values

  # Still waiting for a name: no kept voice, and no real name from a supplied
  # transcript, and not set aside as noise. A pending suggestion doesn't count
  # until someone confirms it.
  def unnamed?
    return false if field_voice&.kept?
    return false if ignored?

    !(field_recording.supplied? && !label.match?(GENERIC_LABEL))
  end

  # A person said this "speaker" is noise (a cough, the room, a mishearing),
  # or a person who can stay anonymous: either way, not someone to name. Only an unnamed speaker can be set aside; naming it
  # later, or un-naming, takes the mark off.
  def ignored? = ignored_at.present? && !field_voice&.kept?

  # Set aside as a person who stays anonymous, rather than as noise.
  def anonymous? = ignored? && ignored_as == "anonymous"

  # A human names this speaker. Every speaker decision (naming, un-naming,
  # confirming or dismissing a suggestion or a guess) takes the one lock order,
  # account → recording → voice, and reloads the speaker under it, so it is
  # serialized with delete-name (which holds the account lock while it gathers
  # and clears every linked recording). The voice must still be kept once
  # locked: a request that resolved it before a delete can't link it after.
  def name_as!(voice, by:, source: "human")
    raise ArgumentError, "voice from another account" unless voice.account_id == field_recording.account_id

    # The voice this speaker was linked to before, and any voice holding a
    # sample of them, are locked too: their prints are rebuilt without it.
    others = [ field_voice, *FieldVoiceprints::Learning.sample_voices([ id ]) ].compact
    FieldVoiceprints::Locks.with(account: field_recording.account, recording: field_recording, voices: [ voice, *others ]) do |_account, recording, voices|
      target = voices.find { |locked| locked.id == voice.id }
      raise ActiveRecord::RecordNotFound unless recording.kept? && recording.ready? && target&.kept?

      reload
      update!(field_voice: target, naming_source: source, named_by: by, named_at: Time.current,
        decision_generation: decision_generation + 1, **SUGGESTION_FIELDS, **RECOGNITION_FIELDS, **NOT_IGNORED, **NO_PROBE)
      FieldVoiceprints::Learning.drop_samples!([ id ])
      recording.update!(transcript_text: recording.render_transcript_text)
      # The explicit naming API and attributed confirmations are deliberate
      # edits. An automatic write with no confirmer must not queue inference.
      if (source == "human" || by.present?) && recording.saved_change_to_transcript_text?
        recording.schedule_summary_refresh
      end
      FieldVoiceprints::Learning.queue!(self) if training_label?
    end
  end

  # account → recording, the naming order, for decisions that link no voice.
  def with_decision_locks(&)
    FieldVoiceprints::Locks.with(account: field_recording.account, recording: field_recording) do |_account, recording, _voices|
      yield recording
    end
  end

  def suggestion? = suggested_name.present? && !field_voice&.kept? && !ignored?

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

      update!(decision_generation: decision_generation + 1, **SUGGESTION_FIELDS, **NO_PROBE)
      true
    end
  end

  def recognition? = recognised_voice_id.present? && !field_voice&.kept? && !ignored? && recognised_voice&.kept?

  # The guess a chip showed: which voice, from which print, against which
  # decision generation. Confirm and dismiss must send it back unchanged.
  def recognition_token
    return nil unless recognition?

    { voice_id: recognised_voice.to_param, print_generation: recognition_print_generation,
      decision_generation: recognition_decision_generation, cohort: recognition_cohort }
  end

  # A person confirms "Tomás?" (spec §9). Under account → recording → voice
  # locks, with the speaker reloaded: both gates open, the guess still exactly
  # the one the chip showed (same voice, same print generation, no decision
  # since), the voice kept and its print still current, and the matching
  # snapshot the guess was made in (its cohort key) still the live one, with
  # this print active in it. Anything stale is refused and changes nothing. A confirmed guess is a person's decision, so
  # it teaches the print (confirmed_recognition).
  def confirm_recognition!(by:, shown:)
    # Every voice in the account is locked: the cohort key covers all of them,
    # and Forget and validation take voice locks.
    with_recognition_locks(shown, all_voices: true) do |account, voice|
      active, key = FieldVoiceprints::Cohort.active(account)
      # A checked guess needs its print still active; an unchecked hint
      # ("maybe Anna?") only needs its print still current in the cohort.
      eligible = recognition_checked == false ? FieldVoiceprints::Cohort.prints(account) : active
      next false unless FieldVoiceprints.enabled_for?(account) && voice&.kept? &&
                        recognition_print_generation == voice.print_generation &&
                        recognition_cohort.present? && recognition_cohort == key &&
                        eligible.any? { |print| print.field_voice_id == voice.id && print.generation == voice.print_generation }

      name_as!(voice, by:, source: "confirmed_recognition")
      true
    end
  end

  # Dismissing is allowed with the gates shut (it only removes a guess), but
  # only for the guess the chip showed.
  def dismiss_recognition!(shown:)
    with_recognition_locks(shown) do
      update!(decision_generation: decision_generation + 1, **RECOGNITION_FIELDS, **NO_PROBE)
      true
    end
  end

  def with_recognition_locks(shown, all_voices: false)
    shown = (shown || {}).to_h.symbolize_keys
    voice = FieldVoice.find_by(id: FieldVoice.decode_id(shown[:voice_id].to_s))
    recording = field_recording
    voices = all_voices && voice ? FieldVoice.where(account_id: recording.account_id).to_a : [ voice ].compact
    FieldVoiceprints::Locks.with(account: recording.account, recording:, voices:) do |account, locked_recording, locked|
      reload
      live_voice = locked.find { |candidate| candidate.id == voice&.id }
      current = locked_recording.kept? && locked_recording.ready? && live_voice && !field_voice&.kept? &&
        recognised_voice_id == live_voice.id &&
        recognition_print_generation.to_s == shown[:print_generation].to_s &&
        recognition_decision_generation.to_s == shown[:decision_generation].to_s &&
        decision_generation.to_s == shown[:decision_generation].to_s &&
        recognition_cohort.to_s == shown[:cohort].to_s
      next false unless current

      yield account, live_voice
    end
  end

  def unname!
    voices = [ field_voice, *FieldVoiceprints::Learning.sample_voices([ id ]) ].compact
    FieldVoiceprints::Locks.with(account: field_recording.account, recording: field_recording, voices:) do |_account, recording, _voices|
      # Same guard as name_as!: a request that found the recording before a
      # discard must not change it after waiting for the lock.
      raise ActiveRecord::RecordNotFound unless recording.kept? && recording.ready?

      reload
      update!(field_voice: nil, naming_source: nil, named_by: nil, named_at: nil,
        decision_generation: decision_generation + 1, **SUGGESTION_FIELDS, **NOT_IGNORED, **NO_PROBE)
      FieldVoiceprints::Learning.drop_samples!([ id ])
      recording.update!(transcript_text: recording.render_transcript_text)
      recording.schedule_summary_refresh if recording.saved_change_to_transcript_text?
    end
  end

  # Set aside as noise. Bumping the decision generation keeps the suggestion
  # and recognition jobs off it, as any person's decision does; a guess or
  # suggestion already shown is cleared. A named speaker is refused: un-name
  # it first. Returns false (changing nothing) when it was named meanwhile.
  # as: "noise" (not a person) or "anonymous" (a person who stays unnamed);
  # setting aside again with the other reason changes only the reason.
  def ignore!(by:, as: "noise")
    raise ArgumentError, "unknown reason #{as.inspect}" unless IGNORED_AS.include?(as)

    with_decision_locks do |recording|
      raise ActiveRecord::RecordNotFound unless recording.kept? && recording.ready?

      reload
      next false if field_voice&.kept?
      next true if ignored? && ignored_as == as

      if ignored?
        update!(ignored_as: as, ignored_by: by)
        next true
      end

      update!(ignored_at: Time.current, ignored_by: by, ignored_as: as, decision_generation: decision_generation + 1,
        **SUGGESTION_FIELDS, **RECOGNITION_FIELDS, **NO_PROBE)
      true
    end
  end

  def unignore!
    with_decision_locks do |recording|
      raise ActiveRecord::RecordNotFound unless recording.kept? && recording.ready?

      reload
      update!(decision_generation: decision_generation + 1, **NOT_IGNORED, **NO_PROBE) if ignored_at.present?
      true
    end
  end

  private

  def touch_recording_for_presentation_changes
    # Counts read the links themselves; picker ordering reads max(named_at).
    # Resolve ownership now, including the old voice, before deletion can
    # remove it. Do not couple roster reloads to other speaker/detail traffic.
    if destroyed? || saved_change_to_field_voice_id? || saved_change_to_named_at?
      voice_ids = destroyed? ? [ field_voice_id ] : [ field_voice_id, field_voice_id_before_last_save ]
      FieldVoiceActivity.refresh!(FieldVoice.where(id: voice_ids).distinct.pluck(:account_id))
    end
    return if destroyed?
    return unless (saved_changes.keys & PRESENTATION_FIELDS).any?

    # Capture the change now, before a subsequent speaker touch clears dirty
    # tracking. Rails coalesces this with other parent saves/touches into one
    # recording after_commit callback per outer transaction, including batches.
    # A rolled-back savepoint rolls back the touch too; no latch survives it.
    field_recording.touch
  end

end
