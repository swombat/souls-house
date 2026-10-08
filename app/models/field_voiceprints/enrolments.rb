# "Remember this voice" (spec §9), as three explicit steps:
#
#   start!    the person ticked the box: a sample is chosen and cut, and kept
#             as a pending enrolment so they can hear it. Nothing is sent.
#   dispatch! they said "use it": rechecked under the account and voice locks,
#             then the sample goes to pyannote.
#   write_back! the print came back: rechecked again under the same locks;
#             only then is the print stored, with a new generation.
#
# Every recheck: both gates open, the voice kept and still the same
# generation it was when consent was given, the enrolment still present
# (forget deletes it), the speaker still named to that voice.
module FieldVoiceprints::Enrolments

  class Refused < StandardError; end

  module_function

  def start!(speaker, by:)
    recording = speaker.field_recording
    voice = speaker.field_voice
    raise Refused, "Voice recognition is off in this Field." unless FieldVoiceprints.enabled_for?(recording.account.reload)
    raise Refused, "Name this speaker first." unless voice&.kept?
    raise Refused, "This recording isn't ready." unless recording.kept? && recording.ready?

    segments = FieldVoiceprints::Sample.segments_for(speaker)
    sample_ms = segments.sum { |from, to| to - from }

    FieldVoiceprints::Sample.cut(recording, segments) do |path|
      voice.with_lock do
        voice.enrolments.where(field_recording_speaker: speaker).destroy_all
        enrolment = voice.enrolments.create!(
          account: recording.account, field_recording_speaker: speaker, start_generation: voice.print_generation,
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

  # Returns the dispatched enrolment, or raises Refused.
  def dispatch!(enrolment, client: PyannoteClient.new)
    account = enrolment.account
    account.with_lock do
      voice = enrolment.field_voice
      voice.lock!
      live = FieldVoiceEnrolment.lock.find_by(id: enrolment.id)
      raise Refused, "This is no longer waiting to be remembered." unless live&.status == "previewing" && !live.expired?

      check!(live, voice)
      job_id = client.voiceprint(url: live.sample.url(expires_in: 1.hour))
      live.update!(status: "dispatched", vendor_job_id: job_id)
      live
    end
  end

  # The vendor answered with a print. Returns true if it was stored.
  def write_back!(enrolment_id, print)
    stored = false
    enrolment = FieldVoiceEnrolment.find_by(id: enrolment_id)
    return false unless enrolment

    enrolment.account.with_lock do
      voice = FieldVoice.lock.find_by(id: enrolment.field_voice_id)
      live = FieldVoiceEnrolment.lock.find_by(id: enrolment_id)
      next unless voice && live

      begin
        check!(live, voice)
      rescue Refused
        live.destroy!
        next
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
      stored = true
    end
    stored
  end

  def check!(enrolment, voice)
    speaker = enrolment.field_recording_speaker
    recording = speaker.field_recording
    raise Refused, "Voice recognition is off in this Field." unless FieldVoiceprints.enabled_for?(enrolment.account.reload)
    raise Refused, "This voice has been forgotten or changed." unless voice.kept? && voice.print_generation == enrolment.start_generation
    raise Refused, "This speaker is named differently now." unless speaker.reload.field_voice_id == voice.id
    raise Refused, "This recording is gone." unless recording.kept?
  end

end
