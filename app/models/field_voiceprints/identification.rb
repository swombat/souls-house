# Guessing who unnamed speakers are, in the house (spec 2026-10-19 §8).
#
# Speakers no person has decided anything about (never named, un-named,
# set aside, or had a guess dismissed) and with at least 4 s of clean speech
# are embedded, once: the embedding is kept on the speaker as its probe, so
# matching again after a print changes costs no audio work. Probes are
# compared with the account's active prints (validated on the samples they're
# built from now). A guess is a chip; a person confirms it.
#
# Embedding happens outside any lock. The write rechecks, under account →
# recording → voices with fresh rows, that recognition is still on, the
# recording is still kept and ready, each speaker is still undecided at the
# generation snapshotted, and each print's generation is unchanged.
module FieldVoiceprints::Identification

  module_function

  # Returns the number of guesses written, or nil when nothing could run.
  def run!(recording, client: FieldVoiceprints::VoiceEmbeddings)
    account = recording.account
    return nil unless FieldVoiceprints.enabled_for?(account) && recording.kept? && recording.ready? && !recording.supplied?

    prints = active_prints(account)
    return nil if prints.empty?

    profile = prints.first.profile
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

    voices = FieldVoice.where(id: generations.keys).to_a
    FieldVoiceprints::Locks.with(account:, recording:, voices:) do |live_account, live_recording, live_voices|
      next nil unless FieldVoiceprints.enabled_for?(live_account) && live_recording.kept? && live_recording.ready?

      current = live_voices.select { |voice| voice.kept? && voice.print_generation == generations[voice.id] }.index_by(&:id)
      written = 0
      live_recording.speakers.each do |speaker|
        next unless snapshot.key?(speaker.id) && speaker.decision_generation == snapshot[speaker.id] && undecided?(speaker)

        if fresh[speaker.id]
          speaker.update!(probe_embedding: JSON.generate(fresh[speaker.id]), probe_profile: profile)
        end
        voice_id, score = guesses[speaker.id]
        if voice_id && current[voice_id]
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

  def active_prints(account)
    FieldVoiceprint.joins(:field_voice).merge(FieldVoice.kept).where(account:).where(field_voices: { remember: true })
      .select { |print| print.active? && print.generation == print.field_voice.print_generation }
  end

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
