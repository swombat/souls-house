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
end
