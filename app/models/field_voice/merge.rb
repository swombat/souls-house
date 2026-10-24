# Two names in one Field that turn out to be one person ("Ants" and "Ant
# Hiron"). A person merges one voice into the other: the other is kept, and
# everything the merged voice had moves to it.
#
# A merge is a person saying the two are the same person, so testimony moves
# with it: every speaker named as the merged voice is named as the kept one
# (same naming source, same namer), its samples move across, and a listening
# confirmation that stood for the merged voice stands for the kept one. The
# kept voice's print is rebuilt once from everything, and guesses made from
# either old print are cleared. Nothing is evicted to fit the sample caps:
# a voice over a cap simply takes nothing new until someone reviews.
#
# Under the one lock order (account → recordings → voices), so no naming,
# learning or delete can interleave. The merged voice is discarded.
class FieldVoice::Merge

  class Refused < StandardError; end

  def self.call(...) = new(...).call

  def initialize(source:, into:, name: nil)
    @source = source
    @target = into
    @name = name
  end

  def call
    raise Refused, "Choose another speaker to merge with." if @source.id == @target.id
    raise Refused, "Choose a speaker in this Field." unless @source.account_id == @target.account_id

    account = @source.account
    account.with_lock do
      linked = FieldRecordingSpeaker.where(field_voice_id: @source.id)
      recording_ids = linked.distinct.pluck(:field_recording_id)
      affected_ids = FieldRecordingSpeaker.where(field_voice_id: [ @source.id, @target.id ])
        .or(FieldRecordingSpeaker.where(suggested_voice_id: [ @source.id, @target.id ]))
        .or(FieldRecordingSpeaker.where(recognised_voice_id: [ @source.id, @target.id ]))
        .distinct.pluck(:field_recording_id)
      recordings = FieldRecording.where(id: recording_ids).order(:id).lock.to_a
      source, target = FieldVoice.where(id: [ @source.id, @target.id ]).order(:id).lock.to_a
        .partition { |voice| voice.id == @source.id }.map(&:first)
      raise Refused, "That speaker is no longer in this Field." unless source&.kept? && target&.kept?
      if source.user_id && target.user_id && source.user_id != target.user_id
        raise Refused, "#{source.name} and #{target.name} are two different members, so they can't be merged."
      end

      name = (@name.presence || target.name).to_s.squish
      unless [ source.name, target.name ].any? { |option| option.casecmp?(name) }
        raise Refused, "Keep one of the two names; rename afterwards if you need a new one."
      end

      move!(source, target)
      user_id = source.user_id || target.user_id
      source.update_columns(print_generation: source.print_generation + 1,
        learning_generation: source.learning_generation + 1, remember: false, updated_at: Time.current)
      source.discard!
      old_names = [ source.name, target.name ].map(&:downcase)
      target.update!(name:, user_id:)
      point_suggestions!(account, [ source.id, target.id ], old_names, target)
      if target.remember?
        FieldVoiceprints::Learning.rebuild!(target)
      else
        # A forgotten voice holds no samples; what moved in is forgotten too.
        FieldVoiceSample.where(field_voice_id: target.id).destroy_all
        FieldVoiceprint.where(field_voice_id: target.id).destroy_all
      end

      recordings.each { |recording| recording.update!(transcript_text: recording.render_transcript_text) if recording.ready? }
      FieldRecordingActivity.refresh!(affected_ids)
      FieldVoiceActivity.refresh!([ account.id ])
      ActiveRecord.after_all_transactions_commit do
        FieldVoiceprints::Learning.queue_account!(account, voice: target) if target.remember?
      end
      target
    end
  end

  private

  # Accepting a suggestion resolves it by its name, so every suggestion must
  # say the kept name: one still reading the merged-away name would make that
  # voice again. Suggestions of either voice point at the kept one. A name-only
  # suggestion is relabelled but not linked: never by name equality.
  def point_suggestions!(account, voice_ids, old_names, target)
    FieldRecordingSpeaker.where(suggested_voice_id: voice_ids)
      .update_all(suggested_voice_id: target.id, suggested_name: target.name)
    named = FieldRecordingSpeaker.joins(:field_recording).where(field_recordings: { account_id: account.id })
      .where(suggested_voice_id: nil).where("lower(field_recording_speakers.suggested_name) IN (?)", old_names)
    recording_ids = named.distinct.pluck(:field_recording_id)
    named.update_all(suggested_name: target.name)
    FieldRecordingActivity.refresh!(recording_ids)
  end

  def move!(source, target)
    speakers = FieldRecordingSpeaker.where(field_voice_id: source.id).to_a
    samples = FieldVoiceSample.where(field_voice_id: source.id).to_a
    taken = FieldVoiceSample.where(field_voice_id: target.id).where.not(field_recording_speaker_id: nil)
      .pluck(:field_recording_speaker_id).to_set

    # Which confirmations stood before anything moves: they're measured
    # against the source revision, which names the voice.
    standing = samples.to_h { |sample| [ sample.id, sample.manually_confirmed? ] }

    FieldVoiceprint.where(field_voice_id: source.id).destroy_all
    speakers.each do |speaker|
      # A job in flight for the old voice fails its voice check; it mustn't
      # leave the speaker waiting on it.
      pending = speaker.sample_learning_status == "pending"
      speaker.update!(field_voice: target, **(pending ? { sample_learning_status: nil, sample_learning_error: nil } : {}),
        **FieldRecordingSpeaker::RECOGNITION_FIELDS)
    end

    samples.each do |sample|
      if sample.field_recording_speaker_id && taken.include?(sample.field_recording_speaker_id)
        sample.destroy!
        next
      end

      sample.field_voice = target
      sample.assign_attributes(rollback_embedding: nil, rollback_profile: nil)
      if sample.standalone?
        sample.source_digest = FieldVoiceSamples::Uploads.source_digest(sample)
        sample.confirmed_digest = sample.source_digest if standing[sample.id]
        sample.save!
      else
        speaker = sample.field_recording_speaker
        moved = speaker && speaker.field_voice_id == target.id && sample.source_segments.is_a?(Array) &&
          sample.source_digest.present?
        if moved
          sample.source_digest = FieldVoiceSample.source_digest_for(speaker, sample.source_segments)
          speaker.update!(sample_confirmed_digest: sample.source_digest) if standing[sample.id]
        end
        sample.save!
      end
    end

    FieldRecordingSpeaker.where(recognised_voice_id: [ source.id, target.id ])
      .update_all(recognised_voice_id: nil, recognition_confidence: nil, recognition_print_generation: nil,
        recognition_decision_generation: nil, recognition_cohort: nil, recognition_checked: nil)
  end

end
