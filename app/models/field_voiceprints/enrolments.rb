# "Remember this voice" (spec §9), as three explicit steps, each under the
# full lock order (FieldVoiceprints::Locks: account → recording → voice):
#
#   start!      the person ticked the box. Under the locks, a snapshot is taken
#               of what they consented to: the voice's print generation and the
#               speaker's decision generation, with both gates open and the
#               speaker named to that voice. The sample is cut outside the
#               locks, then the same snapshot is rechecked under the locks
#               before the preview is stored. If anything moved (a forget, a
#               rename, a discard, a gate shut), the sample is thrown away.
#               Nothing is sent.
#   dispatch!   they said "use it". Rechecked under the locks, then sent while
#               they're held. Any vendor error ends the enrolment for good: an
#               uncertain send is never retried silently on the same consent.
#   write_back! the print came back. Rechecked under the locks again,
#               including that the enrolment is still dispatched; only then is
#               the print stored with a new generation.
module FieldVoiceprints::Enrolments

  class Refused < StandardError; end

  # dispatch! couldn't confirm the vendor received the sample. Nothing will be
  # stored from it; the person can tick the box again.
  class Uncertain < StandardError; end

  module_function

  def start!(speaker, by:)
    recording = speaker.field_recording
    snapshot = locked(speaker) do |account, live_recording, voice, live_speaker|
      check_consentable!(account, live_recording, voice, live_speaker)
      { voice_id: voice.id, print_generation: voice.print_generation, decision_generation: live_speaker.decision_generation,
        segments: FieldVoiceprints::Sample.segments_for(live_speaker) }
    end
    sample_ms = snapshot[:segments].sum { |from, to| to - from }

    FieldVoiceprints::Sample.cut(recording, snapshot[:segments]) do |path|
      locked(speaker) do |account, live_recording, voice, live_speaker|
        check_consentable!(account, live_recording, voice, live_speaker)
        unless voice.id == snapshot[:voice_id] && voice.print_generation == snapshot[:print_generation] &&
               live_speaker.decision_generation == snapshot[:decision_generation]
          raise Refused, "Something changed while the sample was being prepared. Nothing was kept; please try again."
        end

        FieldVoiceEnrolment.where(field_voice: voice, field_recording_speaker: live_speaker).find_each(&:destroy!)
        enrolment = FieldVoiceEnrolment.create!(
          account:, field_voice: voice, field_recording_speaker: live_speaker,
          start_generation: snapshot[:print_generation], decision_generation: snapshot[:decision_generation],
          sample_ms:, consented_by: by, consent_text_version: FieldVoiceprints::CONSENT_TEXT_VERSION,
          expires_at: FieldVoiceprints::ENROLMENT_TTL.from_now
        )
        enrolment.sample.attach(io: File.open(path), filename: "sample.wav", content_type: "audio/wav")
        enrolment
      end
    end
  rescue FieldVoiceprints::Sample::Refused => e
    raise Refused, e.message
  end

  def dispatch!(enrolment, client: PyannoteClient.new)
    result = locked_enrolment(enrolment) do |live, account, recording, voice|
      raise Refused, "This is no longer waiting to be remembered." unless live&.status == "previewing" && !live.expired?

      check!(live, account, recording, voice)
      begin
        job_id = client.voiceprint(url: live.sample.url(expires_in: 1.hour))
      rescue PyannoteClient::Error
        live.destroy! # committed with the transaction; raising here would roll it back
        next :uncertain
      end
      live.update!(status: "dispatched", vendor_job_id: job_id)
      live
    end
    raise Uncertain if result == :uncertain

    result
  end

  # The vendor answered with a print. Returns true if it was stored.
  def write_back!(enrolment_id, print)
    enrolment = FieldVoiceEnrolment.find_by(id: enrolment_id)
    return false unless enrolment

    locked_enrolment(enrolment) do |live, account, recording, voice|
      next false unless live&.status == "dispatched"

      begin
        check!(live, account, recording, voice)
      rescue Refused
        live.destroy!
        next false
      end

      generation = voice.print_generation + 1
      voice.update_columns(print_generation: generation, updated_at: Time.current)
      record = FieldVoiceprint.find_or_initialize_by(field_voice: voice)
      record.assign_attributes(
        account: voice.account, print:, generation:, sample_recording: live.field_recording_speaker.field_recording,
        sample_ms: live.sample_ms, consented_by: live.consented_by, consented_at: live.created_at,
        consent_text_version: live.consent_text_version
      )
      record.save!
      live.destroy!
      true
    end
  end

  # Every check, against the freshly locked rows.
  def check!(enrolment, account, recording, voice)
    speaker = enrolment.field_recording_speaker.reload
    raise Refused, "This voice has been forgotten or changed." unless voice
    raise Refused, "Voice recognition is off in this Field." unless FieldVoiceprints.enabled_for?(account)
    raise Refused, "This voice has been forgotten or changed." unless voice.kept? && voice.print_generation == enrolment.start_generation
    raise Refused, "This speaker is named differently now." unless speaker.field_voice_id == voice.id &&
                                                                  speaker.decision_generation == enrolment.decision_generation
    raise Refused, "This recording is gone." unless recording.kept? && recording.ready?
  end

  def check_consentable!(account, recording, voice, speaker)
    raise Refused, "Voice recognition is off in this Field." unless FieldVoiceprints.enabled_for?(account)
    raise Refused, "Name this speaker first." unless voice&.kept? && speaker.field_voice_id == voice.id
    raise Refused, "This recording isn't ready." unless recording.kept? && recording.ready?
  end

  # account → recording → voice, with the speaker reloaded under them.
  def locked(speaker, &)
    recording = speaker.field_recording
    voice = speaker.reload.field_voice
    FieldVoiceprints::Locks.with(account: recording.account, recording:, voices: [ voice ].compact) do |account, rec, voices|
      yield account, rec, voices.first, speaker.reload
    end
  end

  def locked_enrolment(enrolment)
    recording = enrolment.field_recording_speaker.field_recording
    FieldVoiceprints::Locks.with(account: enrolment.account, recording:, voices: [ enrolment.field_voice ]) do |account, rec, voices|
      yield FieldVoiceEnrolment.lock.find_by(id: enrolment.id), account, rec, voices.first
    end
  end

end
