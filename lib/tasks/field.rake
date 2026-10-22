namespace :field do
  desc "Select voice service profile and queue exact-audio conversion (ENGINE=wespeaker or ecapa)"
  task convert_voice_engine: :environment do
    profiles = { "ecapa" => FieldVoiceprints::Profiles::ECAPA, "wespeaker" => FieldVoiceprints::Profiles::WESPEAKER }
    profile = profiles.fetch(ENV.fetch("ENGINE")) { abort "ENGINE must be ecapa or wespeaker." }
    abort "Voice service is not configured." unless FieldVoiceprints::VoiceEmbeddings.configured?
    # Service may have been replaced already; validate its exact target
    # contract before publishing the configuration switch.
    begin
      FieldVoiceprints::VoiceEmbeddings.health(profile:)
    rescue FieldVoiceprints::VoiceEmbeddings::Unavailable
      abort "Target voice service is not ready; profile was not switched."
    end
    FieldVoiceprints::Conversion.configure!(profile)
    puts "Selected #{profiles.key(profile)}; conversion queued. Check field:voice_conversion_status for activation."
  end

  desc "Report aggregate voice-conversion readiness (ACCOUNT=<id> to limit)"
  task voice_conversion_status: :environment do
    accounts = ENV["ACCOUNT"] ? Account.where(id: ENV["ACCOUNT"]) : Account.all
    counts = Hash.new(0)
    accounts.find_each { |account| counts[FieldVoiceprints::Conversion.presentation(account)[:state]] += 1 }
    puts counts.sort.map { |state, count| "#{state}=#{count}" }.join(" ")
  end

  desc "Retry exact-audio voice conversion (ACCOUNT=<id> required)"
  task retry_voice_conversion: :environment do
    FieldVoiceprints::Conversion.queue!(Account.find(ENV.fetch("ACCOUNT")))
    puts "Conversion queued."
  end

  desc "Retire rollback biometrics after acceptance (CONFIRM=retire required)"
  task retire_voice_rollback: :environment do
    abort "Set CONFIRM=retire only after the engine switch is accepted." unless ENV["CONFIRM"] == "retire"
    abort "Some accounts are not ready." unless Account.find_each.all? { |account| FieldVoiceprints::Conversion.ready?(account) }
    Account.find_each do |account|
      account.with_lock do
        account.field_voices.order(:id).lock.to_a
        abort "An account changed; retry after conversion." unless FieldVoiceprints::Conversion.ready?(account)
        FieldVoiceSample.where(account:).update_all(rollback_embedding: nil, rollback_profile: nil)
      end
    end
    puts "Rollback vectors retired. A follow-up schema migration can now drop the two empty rollback columns."
  end

  # Run after restoring a database backup, before jobs resume (spec §9,
  # "Restoring a database resets biometric state"). A backup taken before
  # someone forgot a voice still holds that voice's samples and print; a forget
  # log in the same database would be rolled back with it, so instead every
  # restored sample, print, kept embedding and guess is cleared, and every
  # voice's generations move on. Names people gave stay, and so does a
  # forgotten voice's "not learning". Then `field:learn_voices` learns again.
  # Runbook order: stop jobs, restore, this task, start jobs.
  desc "Clear all voice-print state after restoring a database backup"
  task reset_biometrics_after_restore: :environment do
    counts = FieldVoiceprints.reset_all!
    puts "Cleared #{counts[:prints]} prints, #{counts[:samples]} samples, " \
         "#{counts[:recognitions]} recognition guesses; moved #{counts[:voices]} voices to a new generation."
  end

  # Learn from every naming a person made or confirmed that has no sample yet
  # (spec 2026-10-19 §6): the backfill, and the step after a restore reset.
  # Queues jobs; each rechecks everything before it writes.
  desc "Queue learning for every eligible naming without a sample (ACCOUNT=<id> to limit)"
  task learn_voices: :environment do
    abort "Record the writer cutover first (field:mark_unproven_namings_unknown)." unless FieldVoiceprints.learning_ready?

    accounts = ENV["ACCOUNT"] ? Account.where(id: ENV["ACCOUNT"]) : Account.where(id: FieldVoice.select(:account_id))
    accounts.find_each do |account|
      puts "#{account.id}: queued #{FieldVoiceprints::Learning.queue_account!(account)}"
    end
  end

  # The held-out check, per voice and in total (spec 2026-10-19 §7.4): queries
  # (held-out samples of that voice), correct, rejected, wrong, false accepts
  # into the print, and whether the print may suggest. Reads; writes nothing.
  desc "Report held-out voice-print accuracy (ACCOUNT=<id>)"
  task voiceprint_report: :environment do
    account = Account.find(ENV.fetch("ACCOUNT") { abort "Set ACCOUNT=<id>." })
    prints = FieldVoiceprints::Cohort.prints(account)
    stats, passing = FieldVoiceprints::Validation.measure(account, prints)
    totals = Hash.new(0)
    prints.sort_by { |print| print.field_voice.name.downcase }.each do |print|
      entry = stats[print.field_voice_id]
      next unless entry

      entry.each { |key, value| totals[key] += value }
      verdict = passing.include?(print.field_voice_id) ? "suggests" : "not yet checked"
      puts format("%-28s %2d rec  queries %2d  correct %2d  rejected %2d  wrong %2d  false accepts into %2d  negatives %3d  %s",
        print.field_voice.name.truncate(28), print.recording_count, entry["queries"], entry["correct"], entry["rejected"],
        entry["wrong"], entry["false_accepts_into"], entry["negatives"], verdict)
    end
    voices = stats.count { |_, entry| entry["queries"].positive? }
    puts "Total: #{totals['queries']} queries over #{voices} voices, #{totals['correct']} correct, " \
         "#{totals['rejected']} rejected, #{totals['wrong']} wrong."
    puts "Insufficient evidence (fewer than 30 queries across 5 voices)." if totals["queries"] < 30 || voices < 5
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
    Setting.instance.update!(field_naming_cutover_at: before)
    puts "Marked #{count} namings recorded as human before #{before.iso8601} as unknown; learning may start."
  end
end
