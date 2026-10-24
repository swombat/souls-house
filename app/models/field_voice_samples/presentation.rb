# Deliberate public projection: never serialize an encrypted vector, blob key,
# filesystem path, or the unbounded metadata of an attached recording.
module FieldVoiceSamples::Presentation

  module_function

  def row(sample)
    speaker = sample.field_recording_speaker
    recording = sample.field_recording || speaker&.field_recording
    current = sample.source_current?
    confirmed = sample.manually_confirmed?
    standalone = speaker.nil?
    {
      id: sample.to_param, voice_id: sample.field_voice.to_param,
      speaker_id: speaker&.to_param, recording_id: recording&.to_param,
      kind: standalone ? "upload" : "recording", digest: sample.source_digest,
      content_sha256: sample.content_sha256, source_identifier: sample.source_identifier,
      source_sha256: sample.source_sha256, source_session: sample.source_session,
      source_group_key: sample.source_group_key,
      start_ms: sample.start_ms, end_ms: sample.end_ms,
      recorded_at: sample.recorded_at&.iso8601 || recording&.recorded_at&.iso8601,
      duration_ms: sample.speech_ms, segments: sample.source_segments,
      included: sample.eligible?, confirmed:, source_current: current,
      removed: sample.removed_at.present?,
      ready: sample.embedding.present?,
      state: state(sample, current:, confirmed:),
      label: standalone ? "Uploaded candidate" : speaker.default_name,
      recording_title: standalone ? sample.source_identifier : recording.title,
      confirmed_by: standalone ? sample.confirmed_by&.full_name : speaker.sample_confirmed_by&.full_name,
      confirmed_at: (standalone ? sample.confirmed_at : speaker.sample_confirmed_at)&.iso8601
    }
  end

  def state(sample, current:, confirmed:)
    return "removed" if sample.removed_at.present? || sample.excluded?
    return "not_ready" unless current
    return sample.learning_status == "error" ? "not_ready" : "preparing" if sample.embedding.blank?
    return "confirmed" if sample.eligible? && confirmed
    return "removed" if confirmed && !sample.eligible?

    "review"
  end

end
