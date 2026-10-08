# Deletes a finished transcript from ElevenLabs once we hold our own copy, or
# once it's been ignored as stale (spec §5). Scribe keeps transcripts unless
# asked, and zero-retention mode is enterprise-only.
#
# With no transcription id there's nothing to delete; the dispatch records
# that, and learning the id later queues this job again (learn_ids!).
#
# A 404 is ambiguous: an attempt we abandoned may still be running at the
# vendor and its transcript can appear later. For a transcript we accepted,
# 404 means it's already gone. For any other attempt the job tries again,
# a bounded number of times, then records the limitation and stops, visibly.
module FieldRecordings
  class DeleteVendorTranscriptJob < ApplicationJob

    queue_as :default

    NOT_FOUND_WAITS = [ 10.minutes, 30.minutes, 2.hours, 6.hours ].freeze
    NOT_FOUND = "not found at the vendor after #{NOT_FOUND_WAITS.size + 1} tries".freeze

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

      result = client.delete(transcription_id)
      if result == :deleted || dispatch.outcome == "succeeded"
        dispatch.update!(vendor_deleted_at: Time.current, vendor_delete_error: nil)
      else
        not_found_yet(dispatch)
      end
    rescue ElevenLabsScribe::PermanentError => e
      dispatch.update!(vendor_delete_error: e.message.truncate(255))
      Rails.logger.warn("Scribe transcript delete refused for dispatch #{dispatch.id}: #{e.message}")
    end

    private

    def not_found_yet(dispatch)
      attempts = dispatch.vendor_delete_attempts + 1
      if attempts > NOT_FOUND_WAITS.size
        dispatch.update!(vendor_delete_attempts: attempts, vendor_delete_error: NOT_FOUND)
      else
        dispatch.update!(vendor_delete_attempts: attempts)
        self.class.set(wait: NOT_FOUND_WAITS[attempts - 1]).perform_later(dispatch.id)
      end
    end

  end
end
