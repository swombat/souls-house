# The two gates on voice recognition (spec §9). The house gate is deploy
# configuration, outside the database, so restoring a database can never
# switch recognition back on. It also requires the backup retention to be
# stated (a precondition in the spec) and pyannote to be configured. The
# account gate is `recognise_voices`, off by default.
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
    ENV["SOULSHOUSE_FIELD_VOICEPRINTS"] == "on" && backup_retention_days.present? && PyannoteClient.configured?
  end

  def enabled_for?(account)
    house_enabled? && account.recognise_voices?
  end

  def backup_retention_days
    days = ENV["SOULSHOUSE_BACKUP_RETENTION_DAYS"].to_s
    days.match?(/\A\d+\z/) ? days.to_i : nil
  end

  # Forget every print in an account. Never gated.
  def forget_all!(account)
    account.field_voices.find_each(&:forget!)
  end

  # The restore reset (lib/tasks/field.rake). Never gated.
  def reset_all!
    counts = { prints: FieldVoiceprint.count, enrolments: FieldVoiceEnrolment.count,
               recognitions: FieldRecordingSpeaker.where.not(recognised_voice_id: nil).count, voices: FieldVoice.count }
    FieldVoice.update_all("print_generation = print_generation + 1")
    FieldVoiceprint.delete_all
    FieldVoiceEnrolment.find_each(&:destroy!)
    FieldRecordingSpeaker.where.not(recognised_voice_id: nil)
      .update_all(recognised_voice_id: nil, recognition_confidence: nil, recognition_print_generation: nil)
    counts
  end

end
