# Deletes a finished transcript from ElevenLabs once we hold our own copy, or
# once it's been ignored as stale (spec §5). Scribe keeps transcripts unless
# asked, and zero-retention mode is enterprise-only.
#
# With no transcription id there's nothing to delete; the dispatch records
# that, and learning the id later queues this job again (learn_ids!).
module FieldRecordings
  class DeleteVendorTranscriptJob < ApplicationJob

    queue_as :default

    retry_on ElevenLabsScribe::TransientError, wait: :polynomially_longer, attempts: 3 do |job, error|
      FieldRecordingDispatch.where(id: job.arguments.first).update_all(vendor_delete_error: error.message.truncate(255))
    end

    def perform(dispatch_id, client: ElevenLabsScribe.new)
      dispatch = FieldRecordingDispatch.find_by(id: dispatch_id)
      return unless dispatch&.needs_vendor_cleanup?

      transcription_id = dispatch.with_lock do
        dispatch.update!(vendor_delete_error: FieldRecordingDispatch::NO_ID) if dispatch.transcription_id.blank?
        dispatch.transcription_id
      end
      return if transcription_id.blank?

      client.delete(transcription_id)
      dispatch.update!(vendor_deleted_at: Time.current, vendor_delete_error: nil)
    rescue ElevenLabsScribe::PermanentError => e
      dispatch.update!(vendor_delete_error: e.message.truncate(255))
      Rails.logger.warn("Scribe transcript delete refused for dispatch #{dispatch.id}: #{e.message}")
    end

  end
end
