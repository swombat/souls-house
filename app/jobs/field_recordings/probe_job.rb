# Reads the uploaded recording's duration, then reserves allowance or refuses
# it (spec §4, §6). The probe runs after the upload because the server can't
# see the bytes before then; the browser's own duration check is advisory.
module FieldRecordings
  class ProbeJob < ApplicationJob

    queue_as :default

    UNREADABLE = "This file has no audio we can read."
    MISSING = "The upload didn't arrive. Please upload the file again."

    def perform(recording_id)
      recording = FieldRecording.find_by(id: recording_id)
      return unless recording&.kept? && recording.probing?

      duration_ms = recording.audio.blob.open { |file| FieldRecording::Probe.duration_ms(file.path) }
      if duration_ms
        recording.admit!(duration_ms)
      else
        recording.reject_unreadable!(UNREADABLE)
      end
    rescue ActiveStorage::FileNotFoundError, ActiveStorage::IntegrityError
      recording&.reject_unreadable!(MISSING)
    end

  end
end
