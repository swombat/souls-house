# Guessing who unnamed speakers are, in the house (spec 2026-10-19 §8).
#
# Speakers no person has decided anything about (never named, un-named,
# set aside, or had a guess dismissed) and with at least 4 s of clean speech
# are embedded, once: the embedding is kept on the speaker as its probe, so
# matching again after a print changes costs no audio work. Probes are
# compared with the account's active prints (FieldVoiceprints::Cohort). A
# guess is a chip; a person confirms it.
#
# Embedding happens outside any lock. The write happens under account →
# recording → every voice in the cohort, with fresh rows, and only if
# nothing the guesses were computed from has moved: recognition still on, the
# recording kept and ready, the cohort digest unchanged (so the same prints
# are active, with the same samples; a new competitor or a Forget anywhere
# changes it), the account's probe generation unchanged (Forget all), and each
# speaker still undecided at the generation snapshotted. If the cohort moved,
# nothing is written and the job runs again.
module FieldVoiceprints::Identification

  module_function

  # Returns the number of guesses written; nil when nothing could run;
  # :changed when the cohort moved while embedding (nothing was written).
  def run!(recording, client: FieldVoiceprints::VoiceEmbeddings)
    account = recording.account
    return nil unless FieldVoiceprints.enabled_for?(account) && recording.kept? && recording.ready? && !recording.supplied?

    prints, digest = FieldVoiceprints::Cohort.active(account)
    return nil if prints.empty?

    probe_generation = account.field_probe_generation
    profile = prints.max_by(&:updated_at).profile
    prints = prints.select { |print| print.profile == profile }
    candidates = recording.speakers.select { |speaker| undecided?(speaker) }
    return nil if candidates.empty?

    probes = {}
    fresh = {}
    candidates.each do |speaker|
      if speaker.probe_profile == profile && speaker.probe_embedding.present?
        probes[speaker.id] = JSON.parse(speaker.probe_embedding)
      else
        vector = embed(speaker, recording, client, profile)
        next unless vector

        probes[speaker.id] = fresh[speaker.id] = vector
      end
    end
    snapshot = candidates.to_h { |speaker| [ speaker.id, speaker.decision_generation ] }
    generations = prints.to_h { |print| [ print.field_voice_id, print.generation ] }
    guesses = FieldVoiceprints::Matching.guesses(probes, prints.to_h { |print| [ print.field_voice_id, print.vector ] })

    voices = FieldVoice.where(account:).to_a
    FieldVoiceprints::Locks.with(account:, recording:, voices:) do |live_account, live_recording, _voices|
      next nil unless FieldVoiceprints.enabled_for?(live_account) && live_recording.kept? && live_recording.ready?
      next nil unless live_account.field_probe_generation == probe_generation
      next :changed unless FieldVoiceprints::Cohort.active(live_account).last == digest

      written = 0
      live_recording.speakers.each do |speaker|
        next unless snapshot.key?(speaker.id) && speaker.decision_generation == snapshot[speaker.id] && undecided?(speaker)

        speaker.update!(probe_embedding: JSON.generate(fresh[speaker.id]), probe_profile: profile) if fresh[speaker.id]
        voice_id, score = guesses[speaker.id]
        if voice_id
          speaker.update!(recognised_voice_id: voice_id, recognition_confidence: (score * 100).round,
            recognition_print_generation: generations[voice_id], recognition_decision_generation: speaker.decision_generation)
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

  def undecided?(speaker)
    speaker.decision_generation.zero? && !speaker.field_voice&.kept? && !speaker.ignored?
  end

  def embed(speaker, recording, client, profile)
    segments = FieldVoiceprints::Sample.segments_for(speaker)
    result = FieldVoiceprints::Sample.cut(recording, segments) { |path| client.embed(File.binread(path)) }
    result.profile == profile ? result.embedding : nil
  rescue FieldVoiceprints::Sample::Refused
    nil
  end

  # Recordings in an account with someone left to guess at. Matching them
  # again is cheap once their probes are kept.
  def recordings_to_match(account)
    FieldRecording.kept.where(account:, status: "ready")
      .where(id: FieldRecordingSpeaker.where(decision_generation: 0, field_voice_id: nil, ignored_at: nil).select(:field_recording_id))
  end

end
