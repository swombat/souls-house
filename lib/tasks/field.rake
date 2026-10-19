namespace :field do
  # Run after restoring a database backup, BEFORE workers or recognition
  # resume (spec §9, "Restoring a database resets biometric state"). A backup
  # taken before someone forgot a voice still holds that print; a forget log in
  # the same database would be rolled back with it, so instead every restored
  # print, pending enrolment and recognition guess is cleared, and every voice's
  # generation moves on. Names people gave stay. Recognition then needs fresh
  # consent. Runbook order: house flag off, restore, this task, flag back on.
  desc "Clear all voice-print state after restoring a database backup"
  task reset_biometrics_after_restore: :environment do
    counts = FieldVoiceprints.reset_all!
    puts "Cleared #{counts[:prints]} prints, #{counts[:enrolments]} pending enrolments, " \
         "#{counts[:recognitions]} recognition guesses; moved #{counts[:voices]} voices to a new generation."
  end

  # The writer cutover for slice A (spec 2026-10-19 §11). Run once every web
  # and jobs process is on provenance-aware code, and before any voice-print
  # learning or backfill starts. BEFORE is when the last old process stopped
  # (ISO 8601); "human" namings from before then become "unknown". Rolling
  # back to old writers means running it again afterwards.
  desc "Mark namings an old writer may have recorded as human as unknown (BEFORE=<time old writers stopped>)"
  task mark_unproven_namings_unknown: :environment do
    before = Time.iso8601(ENV.fetch("BEFORE") { abort "Set BEFORE to when the last old web/jobs process stopped (ISO 8601)." })
    count = FieldRecordingSpeaker.mark_unproven_namings_unknown!(before:)
    puts "Marked #{count} namings recorded as human before #{before.iso8601} as unknown."
  end
end
