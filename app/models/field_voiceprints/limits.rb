# Capacity decisions are made under account → recording → voice locks.
# Existing evidence is never evicted to make space for new evidence.
module FieldVoiceprints::Limits

  ACTIVE = 20
  PENDING = 20
  MIN_CONFIRMED = 2

  class Reached < StandardError; end

  module_function

  def active!(voice, except: nil)
    rows = voice.samples.where(eligible: true)
    rows = rows.where.not(id: except.id) if except&.persisted?
    raise Reached, "This speaker already has twenty included samples. Exclude one explicitly first." if rows.count >= ACTIVE
  end

  # Twenty included samples is as many as a print uses (Daniel, Ypzyaj
  # 2026-10-27): from then on no new candidate is offered for review. A
  # speaker whose sample is already included can still be refreshed.
  def full?(voice, speaker: nil)
    rows = voice.samples.where(eligible: true)
    return false if speaker && rows.where(field_recording_speaker_id: speaker.id).exists?

    rows.count >= ACTIVE
  end

  def pending_count(voice, except_sample: nil, except_speaker: nil)
    rows = voice.samples.to_a.reject { |sample|
      sample.id == except_sample&.id || (except_speaker && sample.field_recording_speaker_id == except_speaker.id) ||
        sample.removed_at.present? || (sample.standalone? && sample.excluded?) ||
        (!sample.standalone? && sample.field_recording_speaker&.sample_excluded?) || sample.manually_confirmed?
    }
    speaker_ids = rows.filter_map(&:field_recording_speaker_id)
    waiting = voice.speakers.where(sample_learning_status: "pending").where.not(id: speaker_ids)
    waiting = waiting.where.not(id: except_speaker.id) if except_speaker
    rows.size + waiting.count
  end

  def pending!(voice, except_sample: nil, except_speaker: nil)
    if pending_count(voice, except_sample:, except_speaker:) >= PENDING
      raise Reached, "This speaker already has twenty samples awaiting review. Review or remove some first."
    end
  end

  # `samples:` is this voice's eligible rows, already loaded
  # with_confirmation_sources (Cohort loads every voice's at once).
  def confirmed_samples(voice, samples: nil)
    samples ||= FieldVoiceSample.with_confirmation_sources.where(field_voice_id: voice.id, eligible: true).to_a
    samples.select { |sample|
      (!sample.respond_to?(:removed_at) || sample.removed_at.nil?) && sample.preloaded_manually_confirmed?
    }
  end

end
