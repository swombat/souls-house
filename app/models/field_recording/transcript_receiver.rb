# The one way a finished transcript enters the house, whether from the webhook
# or the sweep's fetch (spec §5): accept it under the lifecycle guards, then
# queue vendor deletion in every case.
module FieldRecording::TranscriptReceiver

  module_function

  def receive!(dispatch, transcription, request_id: nil)
    result = dispatch.field_recording.accept_transcript!(dispatch, transcription, request_id:)
    FieldRecordings::DeleteVendorTranscriptJob.perform_later(dispatch.id)
    result
  end

end
