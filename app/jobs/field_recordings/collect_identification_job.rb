# Polls an identify job and applies the result under the checks in
# FieldVoiceprints::Identification.apply!. Bounded polling; a failure leaves
# the transcript as it was. Recognition never refunds or consumes allowance.
module FieldRecordings
  class CollectIdentificationJob < ApplicationJob

    queue_as :default

    POLL_EVERY = 30.seconds
    POLL_LIMIT = 60

    def perform(identification_id, client: PyannoteClient.new)
      identification = FieldRecordingIdentification.find_by(id: identification_id, status: "dispatched")
      return unless identification

      result = client.job(identification.vendor_job_id)
      status = result.is_a?(Hash) ? result["status"] : nil
      case status
      when "succeeded"
        output = result["output"]
        output.is_a?(Hash) ? FieldVoiceprints::Identification.apply!(identification, output) : identification.update!(status: "failed")
      when "failed", "canceled"
        identification.update!(status: "failed")
      when "pending", "created", "running"
        poll_again(identification)
      else
        identification.update!(status: "failed")
      end
    rescue PyannoteClient::TransientError
      poll_again(identification) if identification
    rescue PyannoteClient::PermanentError
      identification&.update!(status: "failed")
    end

    private

    def poll_again(identification)
      return identification.update!(status: "failed") if identification.poll_count >= POLL_LIMIT

      identification.increment!(:poll_count)
      self.class.set(wait: POLL_EVERY).perform_later(identification.id)
    end

  end
end
