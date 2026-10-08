# Every 15 minutes: pending "remember this voice" previews past their hour are
# deleted with their samples (spec §9). Leaving the page doesn't keep a voice
# sample around. Dispatched enrolments are left to CollectPrintJob, whose own
# polling is bounded; any still here a day later are dropped too.
module FieldVoices
  class EnrolmentSweepJob < ApplicationJob

    queue_as :default

    DISPATCHED_LIMIT = 1.day

    def perform(now: Time.current)
      FieldVoiceEnrolment.where(status: "previewing").where(expires_at: ..now).find_each(&:destroy!)
      FieldVoiceEnrolment.where(status: "dispatched").where(updated_at: ...(now - DISPATCHED_LIMIT)).find_each(&:destroy!)
    end

  end
end
