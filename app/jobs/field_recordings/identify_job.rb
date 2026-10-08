# Sends a ready recording to identify when recognition is on for its account
# (spec §9), then hands polling to CollectIdentificationJob.
module FieldRecordings
  class IdentifyJob < ApplicationJob

    queue_as :default

    def perform(recording_id, client: PyannoteClient.new)
      recording = FieldRecording.kept.find_by(id: recording_id)
      return unless recording&.ready? && FieldVoiceprints.enabled_for?(recording.account)

      identification = FieldVoiceprints::Identification.dispatch!(recording, client:)
      CollectIdentificationJob.set(wait: CollectIdentificationJob::POLL_EVERY).perform_later(identification.id) if identification
    rescue PyannoteClient::Error
      nil
    end

  end
end
