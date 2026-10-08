# Sending a recording to identify, and using the answer (spec §9), both under
# the full lock order (FieldVoiceprints::Locks: account → recording → voices).
#
# Sending: both gates rechecked, the recording still kept and ready, every
# kept voice with a print locked, only current prints collected, labels opaque
# (never names), and the POST made while the locks are held, so neither a
# gate change, a discard nor a forget can slip between the check and the send.
# Each speaker's decision generation is snapshotted at the same moment.
#
# Using the answer: under the same locks again, a label counts only if its
# voice still has the generation it was sent with, and a speaker is guessed at
# only if no person has decided anything about them, then or since (named,
# un-named, dismissed a guess). A recognition is a guess until confirmed.
module FieldVoiceprints::Identification

  module_function

  def dispatch!(recording, client: PyannoteClient.new)
    account = recording.account
    candidates = account.field_voices.kept.where(id: FieldVoiceprint.where(account:).select(:field_voice_id)).to_a

    FieldVoiceprints::Locks.with(account:, recording:, voices: candidates) do |locked_account, locked_recording, voices|
      next nil unless FieldVoiceprints.enabled_for?(locked_account) && locked_recording.kept? && locked_recording.ready?

      prints = voices.filter_map do |voice|
        print = FieldVoiceprint.find_by(field_voice: voice)
        [ voice, print ] if voice.kept? && print && print.generation == voice.print_generation
      end
      next nil if prints.empty?

      snapshot = {}
      voiceprints = prints.map do |voice, print|
        label = "v#{SecureRandom.hex(4)}"
        snapshot[label] = [ voice.id, print.generation ]
        { label:, voiceprint: print.print }
      end
      decisions = locked_recording.speakers.to_h { |speaker| [ speaker.id.to_s, speaker.decision_generation ] }
      job_id = client.identify(url: locked_recording.audio.blob.url(expires_in: 1.hour), voiceprints:,
        threshold: FieldVoiceprints::IDENTIFY_THRESHOLD, num_speakers: locked_recording.expected_speakers)
      FieldRecordingIdentification.create!(field_recording: locked_recording, vendor_job_id: job_id, snapshot:,
        speaker_decisions: decisions)
    end
  end

  def apply!(identification, output)
    recording = identification.field_recording
    voice_ids = identification.snapshot.values.map(&:first).uniq
    voices = FieldVoice.where(id: voice_ids).to_a

    FieldVoiceprints::Locks.with(account: recording.account, recording:, voices:) do |account, locked_recording, locked|
      next false unless locked_recording.kept? && locked_recording.ready? && identification.reload.status == "dispatched"

      by_id = locked.index_by(&:id)
      valid = if FieldVoiceprints.enabled_for?(account)
        identification.snapshot.select do |_label, (voice_id, generation)|
          voice = by_id[voice_id]
          voice&.kept? && voice.print_generation == generation &&
            FieldVoiceprint.where(field_voice_id: voice_id, generation:).exists?
        end
      else
        {}
      end

      found = FieldVoiceprints::Matching.recognitions(locked_recording.transcript_words || [], output, valid)
      locked_recording.speakers.each do |speaker|
        sent_decision = identification.speaker_decisions[speaker.id.to_s]
        untouched = sent_decision == 0 && speaker.decision_generation.zero? && !speaker.field_voice&.kept?
        next unless untouched

        hit = found[speaker.label]
        speaker.update!(recognised_voice_id: hit&.dig(:voice_id), recognition_confidence: hit&.dig(:confidence),
          recognition_print_generation: hit&.dig(:generation),
          recognition_decision_generation: (speaker.decision_generation if hit))
      end
      identification.update!(status: "done")
      locked_recording.touch
      true
    end
  end

end
