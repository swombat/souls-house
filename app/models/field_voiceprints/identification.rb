# Sending a recording to identify, and using the answer (spec §9).
#
# Sending: under the account lock (so a gate change can't slip between the
# check and the send), then every kept voice with a print locked in id order
# (so a forget can't slip in either). The final check and the POST happen
# while those locks are held. Labels sent are opaque, never names.
#
# Using the answer: under the account, recording and voice locks again, each
# label is used only if its voice still has the same print generation it had
# when sent, and both gates are still open. Speakers a person has named are
# never touched; a recognition is a guess until a person confirms it.
module FieldVoiceprints::Identification

  module_function

  def dispatch!(recording, client: PyannoteClient.new)
    account = recording.account
    account.with_lock do
      next nil unless FieldVoiceprints.enabled_for?(account) && recording.reload.kept? && recording.ready?

      voices = account.field_voices.kept.where(id: FieldVoiceprint.where(account:).select(:field_voice_id)).order(:id).lock.to_a
      prints = voices.filter_map do |voice|
        print = FieldVoiceprint.find_by(field_voice: voice)
        [ voice, print ] if print && print.generation == voice.print_generation
      end
      next nil if prints.empty?

      snapshot = {}
      voiceprints = prints.map do |voice, print|
        label = "v#{SecureRandom.hex(4)}"
        snapshot[label] = [ voice.id, print.generation ]
        { label:, voiceprint: print.print }
      end
      job_id = client.identify(url: recording.audio.blob.url(expires_in: 1.hour), voiceprints:,
        threshold: FieldVoiceprints::IDENTIFY_THRESHOLD, num_speakers: recording.expected_speakers)
      FieldRecordingIdentification.create!(field_recording: recording, vendor_job_id: job_id, snapshot:)
    end
  end

  def apply!(identification, output)
    recording = identification.field_recording
    recording.account.with_lock do
      recording.lock!
      next false unless recording.kept? && recording.ready?

      voice_ids = identification.snapshot.values.map(&:first).uniq.sort
      voices = FieldVoice.where(id: voice_ids).order(:id).lock.index_by(&:id)
      valid = if FieldVoiceprints.enabled_for?(recording.account)
        identification.snapshot.select do |_label, (voice_id, generation)|
          voice = voices[voice_id]
          voice&.kept? && voice.print_generation == generation &&
            FieldVoiceprint.where(field_voice_id: voice_id, generation:).exists?
        end
      else
        {}
      end

      found = FieldVoiceprints::Matching.recognitions(recording.transcript_words || [], output, valid)
      recording.speakers.each do |speaker|
        next if speaker.field_voice&.kept?

        hit = found[speaker.label]
        speaker.update!(recognised_voice_id: hit&.dig(:voice_id), recognition_confidence: hit&.dig(:confidence),
          recognition_print_generation: hit&.dig(:generation))
      end
      identification.update!(status: "done")
      recording.touch
      true
    end
  end

end
