# Restartable engine conversion, deliberately separate from learning. No
# enrollment, extraction selection or listening testimony is written here.
module FieldVoiceprints::Conversion

  module_function

  def queue!(account)
    ActiveRecord.after_all_transactions_commit { FieldVoices::ConvertProfileJob.perform_later(account.id) }
  end

  # No inference or conversion at boot. Only this explicit operator action
  # selects the house's service contract and starts per-account conversion.
  def configure!(profile)
    FieldVoiceprints::Profiles.recipe(profile)
    Setting.instance.update!(voice_embedding_profile: profile)
    Account.find_each { |account| queue!(account) }
  end

  # Include stale/missing sources with listening receipts: they must block
  # activation, not disappear because source_current? has become false.
  def candidates(account)
    FieldVoiceSample.eligible.not_removed.with_confirmation_sources.joins(:field_voice)
      .merge(FieldVoice.kept).where(account:, excluded: false, field_voices: { remember: true })
      .to_a.select do |sample|
        speaker = sample.field_recording_speaker
        if speaker
          !speaker.sample_excluded? && speaker.sample_confirmed_digest.present? &&
            speaker.sample_confirmed_by_id.present? && speaker.sample_confirmed_at.present?
        else
          sample.confirmed_digest.present? && sample.confirmed_by_id.present? && sample.confirmed_at.present?
        end
      end
  end

  # Runtime gate: stale references fall out of their own prints normally.
  # Strict all-source/vector completeness is checked only at activation.
  def ready?(account, profile: FieldVoiceprints::Profiles.configured)
    FieldVoiceprints::Profiles.active(account) == profile &&
      !%w[converting blocked].include?(account.voice_conversion_status)
  end

  def presentation(account)
    return { state: "ready", remaining: 0 } if ready?(account)

    target = FieldVoiceprints::Profiles.configured
    remaining = candidates(account).count { |sample| !sample.preloaded_manually_confirmed? || !sample.vector_for(target) }
    { state: account.voice_conversion_status == "blocked" ? "blocked" : "converting",
      remaining:, message: account.voice_conversion_error.presence ||
        "Voice recognition is paused while confirmed samples change engine. Exclude or remove unavailable samples, then retry." }
  end

  def run!(account, client: FieldVoiceprints::VoiceEmbeddings)
    target = FieldVoiceprints::Profiles.configured
    return :ready if ready?(account, profile: target)

    account.update!(voice_conversion_status: "converting", voice_conversion_error: nil)
    candidates(account).each do |sample|
      break unless FieldVoiceprints::Profiles.configured == target

      convert!(sample, target:, client:)
    end
    activate!(account, target:)
  rescue FieldVoiceprints::VoiceEmbeddings::Unavailable
    block!(account, "The voice service is unavailable. Retry conversion after checking the service.")
    raise
  end

  def convert!(sample, target:, client:)
    return :ready if sample.vector_for(target)
    return :blocked unless sample.manually_confirmed?

    snapshot = snapshot(sample)
    result = if sample.standalone?
      bytes = sample.audio.download
      return :blocked unless Digest::SHA256.hexdigest(bytes) == sample.content_sha256

      client.embed(bytes)
    else
      FieldVoiceprints::Sample.cut(sample.field_recording, sample.source_segments) do |path|
        client.embed(File.binread(path))
      end
    end
    unless result.profile == target && FieldVoiceprints::Profiles.valid_vector?(result.embedding, target)
      raise FieldVoiceprints::VoiceEmbeddings::Unavailable
    end

    FieldVoiceSamples::Uploads.with_sample_lock(sample) do |live|
      next :stale unless snapshot(live) == snapshot && live.manually_confirmed? &&
        live.eligible? && !live.excluded? && live.removed_at.nil? &&
        live.field_voice.kept? && live.field_voice.remember? &&
        !live.field_recording_speaker&.sample_excluded? && FieldVoiceprints::Profiles.configured == target

      # update_columns deliberately preserves updated_at: this is not new
      # testimony, nor a reason to invalidate the old still-active print.
      live.update_columns(rollback_embedding: live.embedding, rollback_profile: live.profile,
        embedding: JSON.generate(result.embedding), profile: target)
      :converted
    end
  rescue ActiveStorage::FileNotFoundError, FieldVoiceprints::Sample::Refused
    :blocked
  rescue ActiveRecord::RecordNotFound
    :stale
  end

  # Account first, then all voices. Every confirmation/learning publication
  # takes the account lock; Forget takes a voice lock. Nothing enrolled can
  # enter or disappear between this readiness check and the atomic switch.
  def activate!(account, target:)
    account.with_lock do
      voices = account.field_voices.order(:id).lock.to_a
      next :stale unless FieldVoiceprints::Profiles.configured == target

      samples = candidates(account)
      unless samples.all? { |sample| sample.preloaded_manually_confirmed? && sample.vector_for(target) }
        block!(account, "Some confirmed samples have unavailable or changed audio. Exclude or remove them on Voices, then retry conversion.")
        next :blocked
      end

      # Rollback is the same operation: swap a compatible retained vector
      # back, without touching source provenance or confirmations.
      samples.each do |sample|
        next if sample.profile == target

        sample.update_columns(embedding: sample.rollback_embedding, profile: sample.rollback_profile,
          rollback_embedding: sample.embedding, rollback_profile: sample.profile)
      end
      account.update!(voice_embedding_profile: target, voice_conversion_status: "ready", voice_conversion_error: nil,
        field_probe_generation: account.field_probe_generation + 1)
      voices.each { |voice| FieldVoiceprints::Learning.rebuild!(voice, profile: target) if voice.kept? && voice.remember? }
      FieldRecordingSpeaker.joins(:field_recording).where(field_recordings: { account_id: account.id })
        .update_all(probe_embedding: nil, probe_profile: nil, recognised_voice_id: nil,
          recognition_confidence: nil, recognition_print_generation: nil, recognition_cohort: nil, recognition_checked: nil,
          recognition_decision_generation: nil)
      FieldVoiceActivity.refresh!([ account.id ])
      FieldRecordingActivity.refresh!(account.field_recordings.pluck(:id))
      FieldVoices::ValidatePrintsJob.queue!(account)
      :activated
    end
  end

  def block!(account, message)
    account.update!(voice_conversion_status: "blocked", voice_conversion_error: message)
    FieldVoiceActivity.refresh!([ account.id ])
  end

  def snapshot(sample)
    speaker = sample.field_recording_speaker
    [ sample.id, sample.field_voice_id, sample.field_voice.learning_generation,
      sample.review_generation, sample.source_digest, sample.source_segments, sample.content_sha256,
      sample.embedding, sample.profile, sample.rollback_embedding, sample.rollback_profile,
      sample.confirmed_digest, sample.confirmed_by_id, sample.confirmed_at,
      speaker&.sample_review_generation, speaker&.sample_confirmed_digest,
      speaker&.sample_confirmed_by_id, speaker&.sample_confirmed_at ]
  end

end
