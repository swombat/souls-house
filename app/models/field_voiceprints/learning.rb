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
      FieldVoices::LearnSampleJob.perform_later(snapshot) if snapshot
    rescue ActiveRecord::RecordNotFound
      nil
    end
  end

  # nil when there's nothing to learn from this speaker as it stands.
  def snapshot_for(speaker)
    voice = speaker.field_voice
    recording = speaker.field_recording
    return nil unless speaker.training_label? && voice.remember? && recording.kept? && recording.ready? &&
                      !recording.supplied? && FieldVoiceprints.enabled_for?(recording.account) &&
                      FieldVoiceprints.learning_ready?

    { "speaker_id" => speaker.id, "decision_generation" => speaker.decision_generation, "voice_id" => voice.id,
      "naming_source" => speaker.naming_source, "learning_generation" => voice.learning_generation,
      "recording_id" => recording.id }
  end

  # Returns :learned, :stale, :no_sample or :gone.
  def learn!(snapshot, client: FieldVoiceprints::VoiceEmbeddings)
    speaker = FieldRecordingSpeaker.find_by(id: snapshot["speaker_id"])
    return :gone unless speaker

    recording = speaker.field_recording
    voice = FieldVoice.find_by(id: snapshot["voice_id"])
    return :stale unless voice && holds?(snapshot, recording.account, recording, voice, speaker)

    segments = FieldVoiceprints::Sample.segments_for(speaker)
    result = FieldVoiceprints::Sample.cut(recording, segments) { |path| client.embed(File.binread(path)) }
    speech_ms = segments.sum { |from, to| to - from }

    FieldVoiceprints::Locks.with(account: recording.account, recording:, voices: [ voice ]) do |account, live_recording, voices|
      live_voice = voices.first
      next :stale unless live_voice && holds?(snapshot, account, live_recording, live_voice, speaker.reload)

      sample = FieldVoiceSample.find_or_initialize_by(field_voice: live_voice, field_recording_speaker: speaker)
      sample.assign_attributes(account:, field_recording_id: live_recording.id, speech_ms:, profile: result.profile,
        label_origin: speaker.naming_source, eligible: true)
      sample.vector = result.embedding
      sample.save!
      rebuild!(live_voice)
      :learned
    end
  rescue FieldVoiceprints::Sample::Refused
    :no_sample
  end

  # Every check in §9, against rows the caller has (re)loaded.
  def holds?(snapshot, account, recording, voice, speaker)
    recording.kept? && recording.ready? && recording.id == snapshot["recording_id"] &&
      FieldVoiceprints.enabled_for?(account) && FieldVoiceprints.learning_ready? &&
      speaker.decision_generation == snapshot["decision_generation"] &&
      speaker.field_voice_id == snapshot["voice_id"] && speaker.training_label? &&
      voice.kept? && voice.remember? && voice.learning_generation == snapshot["learning_generation"]
  end

  # Rebuild a voice's print from all its current eligible samples. The caller
  # holds the voice lock. The print uses one profile, the newest sample's;
  # samples on another profile wait to be learned again (field:learn_voices).
  # Every rebuild moves the generation on, clears guesses made from the old
  # print and leaves the new one unvalidated until Validation runs.
  def rebuild!(voice)
    samples = FieldVoiceSample.eligible.where(field_voice: voice).order(:updated_at, :id).to_a
    profile = samples.last&.profile
    used = samples.select { |sample| sample.profile == profile }
    vector = FieldVoiceprints.centroid(used.map(&:vector))

    generation = voice.print_generation + 1
    voice.update_columns(print_generation: generation, updated_at: Time.current)
    clear_guesses!(voice)

    if vector
      print = FieldVoiceprint.find_or_initialize_by(field_voice: voice)
      print.assign_attributes(account: voice.account, print: JSON.generate(vector), generation:, profile:,
        engine: "ecapa", sample_count: used.size, recording_count: used.map(&:field_recording_id).uniq.size,
        speech_ms: used.sum(&:speech_ms), sample_digest: digest(used), validated: false)
      print.save!
    else
      FieldVoiceprint.where(field_voice: voice).destroy_all
    end
    FieldVoices::ValidatePrintsJob.queue!(voice.account)
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
    learned = FieldVoiceSample.where(account:).pluck(:field_recording_speaker_id).to_set
    scope.includes(:field_voice, :field_recording).find_each.count do |speaker|
      next false if learned.include?(speaker.id)

      snapshot = snapshot_for(speaker)
      FieldVoices::LearnSampleJob.perform_later(snapshot) if snapshot
      snapshot.present?
    end
  end

end
