# Polls pyannote for a dispatched voiceprint and stores it only if every
# check still holds (FieldVoiceprints::Enrolments.write_back!). Bounded: gives
# up after POLL_LIMIT polls and drops the enrolment.
module FieldVoices
  class CollectPrintJob < ApplicationJob

    queue_as :default

    POLL_EVERY = 15.seconds
    POLL_LIMIT = 40

    def perform(enrolment_id, client: PyannoteClient.new)
      enrolment = FieldVoiceEnrolment.find_by(id: enrolment_id, status: "dispatched")
      return unless enrolment

      result = client.job(enrolment.vendor_job_id)
      case result["status"]
      when "succeeded"
        print = result.dig("output", "voiceprint")
        print.is_a?(String) && print.present? ? FieldVoiceprints::Enrolments.write_back!(enrolment.id, print) : enrolment.destroy!
      when "failed", "canceled"
        enrolment.destroy!
      else
        poll_again(enrolment)
      end
    rescue PyannoteClient::TransientError
      poll_again(enrolment) if enrolment
    rescue PyannoteClient::PermanentError
      enrolment&.destroy!
    end

    private

    def poll_again(enrolment)
      return enrolment.destroy! if enrolment.poll_count >= POLL_LIMIT

      enrolment.increment!(:poll_count)
      self.class.set(wait: POLL_EVERY).perform_later(enrolment.id)
    end

  end
end
