# Learning prints from people's namings (spec 2026-10-19 §4, §6, §9).
#
# When a naming a person made or confirmed commits, a job is queued with a
# snapshot of what was decided. The job cuts the speaker's clean speech and
# embeds it outside any lock, then rechecks everything under the lock order
# (account → recording → voice) with fresh rows before writing. Anything a
# person did meanwhile wins: the embedding is dropped.
#
# A write upserts one sample per (voice, speaker) and rebuilds the print from
# all of the voice's current eligible samples, so duplicate delivery writes
# one row and two samples landing in either order give the same print.
module FieldVoiceprints::Learning

  module_function

  # After an eligible naming commits. Never raises into the caller.
  def queue!(speaker)
    ActiveRecord.after_all_transactions_commit do
      snapshot = snapshot_for(speaker.reload)
      enqueue!(snapshot) if snapshot
    rescue ActiveRecord::RecordNotFound
      nil
    end
  end

  # nil when there's nothing to learn from this speaker as it stands.
  def snapshot_for(speaker, allow_excluded: false)
    voice = speaker.field_voice
    recording = speaker.field_recording
    return nil unless (!speaker.sample_excluded? || allow_excluded) &&
                      speaker.training_label? && voice.remember? && recording.kept? && recording.ready? &&
                      !recording.supplied? && recording.audio.attached? && FieldVoiceprints.enabled_for?(recording.account) &&
                      FieldVoiceprints.learning_ready?

    { "speaker_id" => speaker.id, "decision_generation" => speaker.decision_generation, "voice_id" => voice.id,
      "naming_source" => speaker.naming_source, "learning_generation" => voice.learning_generation,
      "recording_id" => recording.id, "review_generation" => speaker.sample_review_generation,
      "excluded" => speaker.sample_excluded?, "allow_excluded" => allow_excluded,
      "source_revision" => FieldVoiceSample.source_revision_for(speaker) }
  end

  def enqueue!(snapshot)
    speaker = FieldRecordingSpeaker.find_by(id: snapshot["speaker_id"])
    return unless speaker

    recording = speaker.field_recording
    voice = speaker.field_voice
    return false unless voice

    FieldVoiceprints::Locks.with(account: recording.account, recording:, voices: [ voice ]) do |account, live_recording, voices|
      next false unless voices.first && holds?(snapshot, account, live_recording, voices.first, speaker.reload)
      next false if speaker.sample_learning_status == "pending"

      FieldVoiceprints::Limits.pending!(voices.first, except_speaker: speaker)
      speaker.update!(sample_learning_status: "pending", sample_learning_error: nil)
      ActiveRecord.after_all_transactions_commit { FieldVoices::LearnSampleJob.perform_later(snapshot) }
      true
    end
  rescue FieldVoiceprints::Limits::Reached
    false
  end

  # Returns :learned, :stale, :no_sample or :gone.
  def learn!(snapshot, client: FieldVoiceprints::VoiceEmbeddings)
    speaker = FieldRecordingSpeaker.find_by(id: snapshot["speaker_id"])
    return :gone unless speaker

    recording = speaker.field_recording
    voice = FieldVoice.find_by(id: snapshot["voice_id"])
    return :stale unless voice && holds?(snapshot, recording.account, recording, voice, speaker)

    segments = FieldVoiceprints::Sample.segments_for(speaker)
    source_digest = FieldVoiceSample.source_digest_for(speaker, segments)
    result = FieldVoiceprints::Sample.cut(recording, segments) { |path| client.embed(File.binread(path)) }
    unless FieldVoiceprints::Profiles.valid_vector?(result.embedding, result.profile) &&
        result.profile == FieldVoiceprints::Profiles.configured
      raise FieldVoiceprints::VoiceEmbeddings::Unavailable
    end
    speech_ms = segments.sum { |from, to| to - from }

    FieldVoiceprints::Locks.with(account: recording.account, recording:, voices: [ voice ]) do |account, live_recording, voices|
      live_voice = voices.first
      next :stale unless live_voice && holds?(snapshot, account, live_recording, live_voice, speaker.reload)

      sample = FieldVoiceSample.find_or_initialize_by(field_voice: live_voice, field_recording_speaker: speaker)
      # An ordinary retry must not replace a confirmed old-engine reference
      # without its rollback copy. Engine conversion has its own writer.
      if sample.persisted? && sample.manually_confirmed?(speaker:) &&
          sample.source_digest == source_digest && sample.profile != result.profile
        FieldVoiceprints::Conversion.queue!(account)
        speaker.update!(sample_learning_status: "learned", sample_learning_error: nil)
        next :stale
      end
      next :stale unless result.profile == FieldVoiceprints::Profiles.configured

      # A naming is a candidate, not testimony that someone heard this cut.
      # A retry of an unchanged, already confirmed cut may keep its inclusion.
      included = sample.persisted? && sample.eligible? && sample.source_digest == source_digest &&
        sample.manually_confirmed?(speaker:)
      FieldVoiceprints::Limits.active!(live_voice, except: sample) if included
      FieldVoiceprints::Limits.pending!(live_voice, except_sample: sample, except_speaker: speaker) unless included
      if sample.source_digest != source_digest
        sample.assign_attributes(rollback_embedding: nil, rollback_profile: nil)
      end
      sample.assign_attributes(account:, field_recording_id: live_recording.id, speech_ms:, profile: result.profile,
        label_origin: speaker.naming_source, eligible: included && !speaker.sample_excluded?,
        source_segments: segments, source_digest:)
      sample.removed_at = nil if snapshot["allow_excluded"]
      sample.vector = result.embedding
      sample.save!
      review = included ? {} : { sample_confirmed_digest: nil, sample_confirmed_by_id: nil, sample_confirmed_at: nil }
      speaker.update!(**review, sample_learning_status: "learned", sample_learning_error: nil)
      rebuild!(live_voice)
      :learned
    end
  rescue FieldVoiceprints::Limits::Reached
    set_status!(snapshot, "no_sample")
    :no_sample
  rescue FieldVoiceprints::Sample::Refused
    set_status!(snapshot, "no_sample")
    :no_sample
  rescue FieldVoiceprints::VoiceEmbeddings::Unavailable
    set_status!(snapshot, "error", error: "The voice service is unavailable. Please try again.")
    raise FieldVoiceprints::VoiceEmbeddings::Unavailable, "The voice service is unavailable.", cause: nil
  rescue ActiveStorage::FileNotFoundError
    set_status!(snapshot, "error", error: "The source audio is unavailable. Check the recording before retrying.")
    :no_sample
  end

  # Every check in §9, against rows the caller has (re)loaded.
  def holds?(snapshot, account, recording, voice, speaker)
    recording.kept? && recording.ready? && recording.id == snapshot["recording_id"] &&
      FieldVoiceprints.enabled_for?(account) && FieldVoiceprints.learning_ready? &&
      speaker.decision_generation == snapshot["decision_generation"] &&
      speaker.sample_review_generation == snapshot["review_generation"] &&
      speaker.sample_excluded? == snapshot["excluded"] &&
      (!speaker.sample_excluded? || snapshot["allow_excluded"] == true) &&
      FieldVoiceSample.source_revision_for(speaker) == snapshot["source_revision"] &&
      speaker.field_voice_id == snapshot["voice_id"] && speaker.training_label? &&
      voice.kept? && voice.remember? && voice.learning_generation == snapshot["learning_generation"]
  end

  # A late failure must not overwrite a newer person's decision or retry.
  def set_status!(snapshot, status, error: nil)
    speaker = FieldRecordingSpeaker.find_by(id: snapshot["speaker_id"])
    voice = FieldVoice.find_by(id: snapshot["voice_id"])
    return unless speaker && voice

    recording = speaker.field_recording
    FieldVoiceprints::Locks.with(account: recording.account, recording:, voices: [ voice ]) do |account, live_recording, voices|
      next unless voices.first && holds?(snapshot, account, live_recording, voices.first, speaker.reload)
      if status == "pending"
        FieldVoiceprints::Limits.pending!(voices.first, except_speaker: speaker)
      end

      speaker.update!(sample_learning_status: status, sample_learning_error: error)
    end
  rescue FieldVoiceprints::Limits::Reached
    false
  end

  # Rebuild a voice's print from all its current eligible samples. The caller
  # holds the voice lock. Only the explicit account profile is used, reading
  # compatible retained rollback pairs while conversion is in progress.
  # Every rebuild moves the generation on, clears guesses made from the old
  # print and leaves the new one unvalidated until Validation runs.
  def rebuild!(voice, profile: FieldVoiceprints::Profiles.active(voice.account))
    samples = FieldVoiceprints::Limits.confirmed_samples(voice).sort_by { |sample| [ sample.updated_at, sample.id ] }
    used = samples.select { |sample| sample.vector_for(profile) }
    vector = FieldVoiceprints.centroid(used.map { |sample| sample.vector_for(profile) }) if used.size >= FieldVoiceprints::Limits::MIN_CONFIRMED

    generation = voice.print_generation + 1
    voice.update_columns(print_generation: generation, updated_at: Time.current)
    clear_guesses!(voice)

    if vector
      print = FieldVoiceprint.find_or_initialize_by(field_voice: voice)
      print.assign_attributes(account: voice.account, print: JSON.generate(vector), generation:, profile:,
        engine: FieldVoiceprints::Profiles.recipe(profile).fetch(:engine),
        sample_count: used.size, recording_count: used.map(&:source_group_key).uniq.size,
        speech_ms: used.sum(&:speech_ms), sample_digest: digest(used), validated: false)
      print.save!
    else
      FieldVoiceprint.where(field_voice: voice).destroy_all
    end
    FieldVoices::ValidatePrintsJob.queue!(voice.account)
    unless FieldVoiceprints::Conversion.ready?(voice.account)
      FieldVoiceprints::Conversion.queue!(voice.account)
    end
  end

  # Which samples a print is built from, so a validation computed on another
  # set never counts for this one.
  def digest(samples)
    Digest::SHA256.hexdigest(samples.map { |sample| "#{sample.id}:#{sample.updated_at.to_f}" }.sort.join(","))
  end

  def clear_guesses!(voice)
    recording_ids = FieldRecordingSpeaker.where(recognised_voice_id: voice.id).distinct.pluck(:field_recording_id)
    return if recording_ids.empty?

    FieldRecordingSpeaker.where(recognised_voice_id: voice.id)
      .update_all(recognised_voice_id: nil, recognition_confidence: nil, recognition_print_generation: nil,
        recognition_decision_generation: nil, recognition_cohort: nil, recognition_checked: nil)
    FieldRecordingActivity.refresh!(recording_ids)
  end

  # A speaker's samples no longer stand (un-named, renamed, lines moved,
  # removed). Destroys them and rebuilds each affected print. The caller holds
  # the locks of every voice in voice_ids (FieldVoiceprints::Locks).
  def drop_samples!(speaker_ids)
    FieldRecordingSpeaker.where(id: speaker_ids).update_all(
      "sample_review_generation = sample_review_generation + 1, sample_learning_status = NULL, sample_learning_error = NULL")
    samples = FieldVoiceSample.where(field_recording_speaker_id: speaker_ids).to_a
    return if samples.empty?

    voice_ids = samples.map(&:field_voice_id).uniq
    FieldVoiceSample.where(id: samples.map(&:id)).delete_all
    FieldVoice.where(id: voice_ids).find_each { |voice| rebuild!(voice) }
  end

  # The voices holding samples of these speakers, to lock before drop_samples!.
  def sample_voices(speaker_ids)
    FieldVoice.where(id: FieldVoiceSample.where(field_recording_speaker_id: speaker_ids).select(:field_voice_id)).to_a
  end

  # A recording was discarded: its samples go and the prints they were in
  # are rebuilt. Jobs for its speakers fail the "recording is kept" check.
  def recording_discarded!(recording)
    speaker_ids = recording.speakers.pluck(:id)
    FieldVoiceprints::Locks.with(account: recording.account, recording:, voices: sample_voices(speaker_ids)) do
      drop_samples!(speaker_ids)
      FieldRecordingSpeaker.where(id: speaker_ids).update_all(probe_embedding: nil, probe_profile: nil)
    end
  end

  # Learning from every eligible naming in an account whose sample is
  # missing (field:learn_voices, "Remember again", after a restore).
  def queue_account!(account, voice: nil)
    scope = FieldRecordingSpeaker.joins(:field_recording).merge(FieldRecording.kept)
      .where(field_recordings: { account_id: account.id }, naming_source: FieldRecordingSpeaker::TRAINING_SOURCES)
      .where.not(field_voice_id: nil)
    scope = scope.where(field_voice_id: voice.id) if voice
    learned = FieldVoiceSample.where(account:).where.not(field_recording_speaker_id: nil).pluck(:field_recording_speaker_id).to_set
    scope.includes(:field_voice, :field_recording).find_each.count do |speaker|
      next false if learned.include?(speaker.id)

      snapshot = snapshot_for(speaker)
      snapshot && enqueue!(snapshot) == true
    end
  end

  # Samples a person can't hear yet: learned before spans were recorded, or
  # their source changed since. Rebuilding one through the usual relearn path
  # gives it real spans; it keeps its inclusion and starts unconfirmed.
  # Returns how many rebuilds were queued.
  def prepare_for_review!(voice)
    return 0 unless voice.kept? && voice.remember?

    FieldVoiceSample.where(field_voice: voice).includes(field_recording_speaker: :field_recording).to_a.count do |sample|
      speaker = sample.field_recording_speaker
      next false unless speaker
      next false unless speaker.field_voice_id == voice.id && speaker.field_recording.kept?
      next false if speaker.sample_learning_status == "pending" || sample.source_current?(speaker:)

      speaker.relearn_sample! == true
    end
  end

  def prepare_account_for_review!(account)
    account.field_voices.kept.where(remember: true).to_a.sum { |voice| prepare_for_review!(voice) }
  end

end
