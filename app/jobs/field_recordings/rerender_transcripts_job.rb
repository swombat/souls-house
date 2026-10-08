# A voice was renamed: every transcript that names it is re-rendered, under
# each recording's lock (spec §7: renaming a voice is the explicit act that
# changes every place it appears).
module FieldRecordings
  class RerenderTranscriptsJob < ApplicationJob

    queue_as :default

    def perform(voice_id)
      FieldRecording.kept.where(id: FieldRecordingSpeaker.where(field_voice_id: voice_id).select(:field_recording_id)).find_each do |recording|
        recording.with_lock do
          recording.update!(transcript_text: recording.render_transcript_text) if recording.ready?
        end
      end
    end

  end
end
