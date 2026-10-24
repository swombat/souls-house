# Guessing who unnamed speakers are, in the house (spec 2026-10-19 §8).
#
# Speakers no person has decided anything about (never named, un-named,
# set aside, or had a guess dismissed) and with at least 4 s of clean speech
# are embedded, once: the embedding is kept on the speaker as its probe, so
# matching again after a print changes costs no audio work. Probes are
# compared with the account's active prints (FieldVoiceprints::Cohort). A
# guess is a chip; a person confirms it.
#
# A speaker no active print claims is then matched against every print in the
# cohort, under the same rules (threshold, margin, split). If the winner is a
# print that hasn't passed its check yet, the speaker gets an unchecked hint
# ("maybe Anna?", recognition_checked false): weaker, said as such, and
# confirmed the same way, which is how such a print earns its second
# recording (Daniel, 2026-10-20, KJkkdJ). An active print never loses a
# speaker it claims to an unchecked one.
#
# A guess from an active print that clears the recipe's naming line
# (FieldVoiceprints::Matching.sure?) names the speaker without a tap when the
# account allows it (Daniel, 2026-10-23, MYnpDj): the naming is a person's
# decision in every respect but authorship (source auto_recognition, named by
# nobody), shown as "named by voice" with "Not them" beside it, and it queues
# a candidate sample that only a person's Accept lets into the print. Hints
# never name, and neither does a guess below the line.
#
# Embedding happens outside any lock. The write happens under account →
# recording → every voice in the cohort, with fresh rows, and only if
# nothing the guesses were computed from has moved: recognition still on, the
# recording kept and ready, the cohort key unchanged (the same prints, with
# the same samples, and the same of them active; a new competitor, a verdict
# or a Forget anywhere changes it), the account's probe generation unchanged
# (Forget all), and each speaker still undecided at the generation
# snapshotted. If the key moved, nothing is written and the job runs again.
# Each guess is stamped with the key, and stands only while it does.
module FieldVoiceprints::Identification

  module_function

  # Returns the number of guesses and namings written; nil when nothing could
  # run; :changed when the cohort moved while embedding (nothing was written).
  def run!(recording, client: FieldVoiceprints::VoiceEmbeddings)
    account = recording.account
    return nil unless FieldVoiceprints.enabled_for?(account) && recording.kept? && recording.ready? && !recording.supplied?
    return :converting unless FieldVoiceprints::Conversion.ready?(account)

    prints, key = FieldVoiceprints::Cohort.active(account)
    cohort = FieldVoiceprints::Cohort.prints(account)
    return nil if cohort.empty?

    probe_generation = account.field_probe_generation
    profile = cohort.first.profile
    candidates = recording.speakers.select { |speaker| undecided?(speaker) }
    return nil if candidates.empty?

    probes = {}
    fresh = {}
    candidates.each do |speaker|
      if (cached = cached_probe(speaker, profile))
        probes[speaker.id] = cached
      else
        vector = embed(speaker, recording, client, profile)
        next unless vector

        probes[speaker.id] = fresh[speaker.id] = vector
      end
    end
    snapshot = candidates.to_h { |speaker| [ speaker.id, speaker.decision_generation ] }
    generations = cohort.to_h { |print| [ print.field_voice_id, print.generation ] }
    guesses = FieldVoiceprints::Matching.guesses(probes, prints.to_h { |print| [ print.field_voice_id, print.vector ] }, profile:)
    hints = unchecked_hints(probes.except(*guesses.keys), cohort, prints)
    sure = sure_guesses(probes, guesses, cohort, profile)

    voices = FieldVoice.where(account:).to_a
    FieldVoiceprints::Locks.with(account:, recording:, voices:) do |live_account, live_recording, locked_voices|
      next nil unless FieldVoiceprints.enabled_for?(live_account) && live_recording.kept? && live_recording.ready?
      next nil unless live_account.field_probe_generation == probe_generation
      next :changed unless FieldVoiceprints::Conversion.ready?(live_account)
      next :changed unless FieldVoiceprints::Cohort.active(live_account).last == key

      naming = FieldVoiceprints.auto_naming_for?(live_account)
      written = 0
      live_recording.speakers.each do |speaker|
        next unless snapshot.key?(speaker.id) && speaker.decision_generation == snapshot[speaker.id] && undecided?(speaker)

        checked = guesses.key?(speaker.id)
        guess = guesses[speaker.id] || hints[speaker.id]
        voice_id, score = guess
        voice = locked_voices.find { |candidate| candidate.id == voice_id } if voice_id
        if checked && naming && voice&.kept? && sure.key?(speaker.id)
          # The naming takes the same locks again, already held by this
          # transaction, and clears the probe as any decision does.
          speaker.name_as!(voice, by: nil, source: "auto_recognition", confidence: (score * 100).round)
          written += 1
          next
        end

        speaker.update!(probe_embedding: JSON.generate(fresh[speaker.id]), probe_profile: profile) if fresh[speaker.id]
        if voice_id
          speaker.update!(recognised_voice_id: voice_id, recognition_confidence: (score * 100).round,
            recognition_print_generation: generations[voice_id], recognition_decision_generation: speaker.decision_generation,
            recognition_cohort: key, recognition_checked: checked)
          written += 1
        elsif speaker.recognised_voice_id
          speaker.update!(**FieldRecordingSpeaker::RECOGNITION_FIELDS, recognition_decision_generation: nil)
        end
      end
      written
    end
  end

  # The prints that may guess now (validated in the current cohort).
  def active_prints(account) = FieldVoiceprints::Cohort.active(account).first

  # The guesses that may name: made again against every print in the cohort,
  # unchecked ones included, the same print must win and clear the naming
  # line. An unchecked print can't name a speaker, but its likeness can keep
  # a checked one from doing so (Mira's review of #509).
  def sure_guesses(probes, guesses, cohort, profile)
    return {} if guesses.empty?

    FieldVoiceprints::Matching.guesses(probes.slice(*guesses.keys), cohort.to_h { |print| [ print.field_voice_id, print.vector ] },
      profile:)
      .select { |key, guess| guess.first == guesses[key].first && FieldVoiceprints::Matching.sure?(guess, profile:) }
  end

  # {probe key => [voice_id, score]} for probes whose best match in the whole
  # cohort is a print that isn't active. Matching against every print keeps
  # the margin honest: an unchecked hint must beat the checked voices too.
  def unchecked_hints(probes, cohort, active)
    return {} if probes.empty?

    active_ids = active.map(&:field_voice_id)
    FieldVoiceprints::Matching.guesses(probes, cohort.to_h { |print| [ print.field_voice_id, print.vector ] },
      profile: cohort.first.profile)
      .reject { |_, (voice_id, _)| active_ids.include?(voice_id) }
  end

  def undecided?(speaker)
    speaker.decision_generation.zero? && !speaker.field_voice&.kept? && !speaker.ignored?
  end

  def embed(speaker, recording, client, profile)
    segments = FieldVoiceprints::Sample.segments_for(speaker)
    result = FieldVoiceprints::Sample.cut(recording, segments) { |path| client.embed(File.binread(path)) }
    result.profile == profile && FieldVoiceprints::Profiles.valid_vector?(result.embedding, profile) ? result.embedding : nil
  rescue FieldVoiceprints::Sample::Refused
    nil
  end

  def cached_probe(speaker, profile)
    return unless speaker.probe_profile == profile && speaker.probe_embedding.present?

    vector = JSON.parse(speaker.probe_embedding)
    vector if FieldVoiceprints::Profiles.valid_vector?(vector, profile)
  rescue JSON::ParserError
    nil
  end

  # Recordings in an account with someone left to guess at. Matching them
  # again is cheap once their probes are kept.
  def recordings_to_match(account)
    FieldRecording.kept.where(account:, status: "ready")
      .where(id: FieldRecordingSpeaker.where(decision_generation: 0, field_voice_id: nil, ignored_at: nil).select(:field_recording_id))
  end

end
