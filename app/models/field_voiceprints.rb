# Voice recognition in the house (docs/2026-10-19-field-voiceprints-in-house.md).
#
# Prints are learned here, from people's namings, by the house's local voice
# service (services/voice-embeddings), and matched here. Audio never leaves
# the house.
#
# Two gates. The house gate is that the voice service is configured: there is
# no other switch (Daniel, 2026-10-19, KJkkdJ: "should just be on"). The
# account gate is `recognise_voices`, on by default, which a Field can turn off
# on its Voices page; off keeps what was learned, unused. Forgetting is never
# gated: it works whatever these say. Backups aren't pruned, so no retention
# is stated or required (Daniel, 2026-10-19).
module FieldVoiceprints

  # A sample is the clean speech of one speaker in one recording. At most
  # 30 s, so a person can listen to it before confirming (Daniel, 2026-10-22,
  # OjyMDj: 20–30 s is digestible, a minute isn't). Uploaded samples keep
  # their own 4–60 s limit (FieldVoiceSamples::Wav).
  MIN_SAMPLE_MS = 4_000
  MAX_SAMPLE_MS = 30_000
  ISOLATION_MS = 1_000

  # Matching recipes are versioned in Profiles; the held-out account check
  # (field:voiceprint_report) uses exactly the same matcher as production.

  module_function

  def house_enabled? = FieldVoiceprints::VoiceEmbeddings.configured?

  def enabled_for?(account)
    house_enabled? && account.recognise_voices?
  end

  # A clear match from a validated print may name a speaker without a tap
  # (Daniel, 2026-10-23, MYnpDj). On by default; a Field that wants every
  # match as a chip turns it off on its Voices page. Never without recognition.
  def auto_naming_for?(account)
    enabled_for?(account) && account.auto_name_voices?
  end

  # Learning reads only namings a person made or confirmed, and only once the
  # slice A writer cutover is recorded (spec §11): before it, a "human" naming
  # may have come from an API key.
  def learning_ready?
    Setting.instance.field_naming_cutover_at.present?
  end

  # Forget every voice in an account, and every unnamed speaker's kept
  # embedding. Never gated. One lock per voice.
  # The probe generation moves on first, so a matching job embedding right
  # now keeps nothing it computed.
  def forget_all!(account)
    Account.where(id: account.id).update_all("field_probe_generation = field_probe_generation + 1")
    account.field_voices.find_each(&:forget!)
    FieldRecordingSpeaker.joins(:field_recording).where(field_recordings: { account_id: account.id })
      .where.not(probe_embedding: nil).update_all(probe_embedding: nil, probe_profile: nil)
  end

  # The restore reset (lib/tasks/field.rake). Never gated. A restored
  # database may hold samples and prints of voices someone forgot after the
  # backup was taken, so all of them go, every voice's generations move on,
  # and guesses are cleared. Names people gave stay; learning starts again
  # from them with `field:learn_voices`.
  def reset_all!
    counts = { prints: FieldVoiceprint.count, samples: FieldVoiceSample.count,
               recognitions: FieldRecordingSpeaker.where.not(recognised_voice_id: nil).count, voices: FieldVoice.count }
    Account.update_all("field_probe_generation = field_probe_generation + 1")
    FieldVoice.update_all("print_generation = print_generation + 1, learning_generation = learning_generation + 1")
    FieldVoiceSample.find_each(&:destroy!)
    FieldVoiceprint.delete_all
    FieldRecordingSpeaker.update_all(sample_learning_status: nil, sample_learning_error: nil,
      sample_confirmed_digest: nil, sample_confirmed_by_id: nil, sample_confirmed_at: nil)
    FieldRecordingSpeaker.where.not(probe_embedding: nil).update_all(probe_embedding: nil, probe_profile: nil)
    FieldRecordingSpeaker.where.not(recognised_voice_id: nil)
      .update_all(recognised_voice_id: nil, recognition_confidence: nil, recognition_print_generation: nil,
        recognition_cohort: nil, recognition_checked: nil)
    counts
  end

  # Cosine similarity of two unit vectors.
  def cosine(a, b)
    raise ArgumentError, "incompatible voice vectors" unless a.size == b.size

    a.each_with_index.sum { |value, index| value * b[index] }
  end

  # The L2-normalised mean of unit vectors, or nil for none.
  def centroid(vectors)
    return nil if vectors.empty?
    return nil unless vectors.all? { |vector| vector.size == vectors.first.size }

    sum = Array.new(vectors.first.length, 0.0)
    vectors.each { |vector| vector.each_with_index { |value, index| sum[index] += value } }
    norm = Math.sqrt(sum.sum { |value| value * value })
    return nil if norm.zero?

    sum.map { |value| value / norm }
  end

end
