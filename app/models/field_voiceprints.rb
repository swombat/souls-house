# The two gates on voice recognition (spec §9). The house gate is deploy
# configuration, outside the database, so restoring a database can never
# switch recognition back on. It also requires pyannote to be configured. The
# account gate is `recognise_voices`, off by default. Backups aren't pruned,
# so no retention is stated or required (Daniel, 2026-10-19).
#
# Forgetting is never gated: it works whatever these say.
module FieldVoiceprints

  CONSENT_TEXT_VERSION = "2026-10-08"
  IDENTIFY_THRESHOLD = 50
  MIN_SAMPLE_MS = 8_000
  MAX_SAMPLE_MS = 30_000
  ISOLATION_MS = 1_000
  ENROLMENT_TTL = 1.hour

  module_function

  def house_enabled?
    ENV["SOULSHOUSE_FIELD_VOICEPRINTS"] == "on" && PyannoteClient.configured?
  end

  def enabled_for?(account)
    house_enabled? && account.recognise_voices?
  end


  # Forget every print in an account. Never gated. Keep one lock/transaction
  # per voice; presentation coalescing must not broaden these locks.
  def forget_all!(account)
    account.field_voices.find_each(&:forget!)
  end

  # The restore reset (lib/tasks/field.rake). Never gated. Operator-only:
  # readers refresh/reconnect after restore, rather than cross-account live
  # fan-out. delete_all deliberately skips print presentation callbacks too.
  def reset_all!
    counts = { prints: FieldVoiceprint.count, enrolments: FieldVoiceEnrolment.count,
               recognitions: FieldRecordingSpeaker.where.not(recognised_voice_id: nil).count, voices: FieldVoice.count }
    FieldVoice.update_all("print_generation = print_generation + 1")
    FieldVoiceprint.delete_all
    FieldVoiceEnrolment.find_each do |enrolment|
      enrolment.skip_broadcast = true
      enrolment.destroy!
    end
    FieldRecordingSpeaker.where.not(recognised_voice_id: nil)
      .update_all(recognised_voice_id: nil, recognition_confidence: nil, recognition_print_generation: nil)
    counts
  end

end
