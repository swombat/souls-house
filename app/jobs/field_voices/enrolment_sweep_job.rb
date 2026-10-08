# Every 15 minutes: pending "remember this voice" previews past their hour are
# deleted with their samples (spec §9). Leaving the page doesn't keep a voice
# sample around. Dispatched enrolments are left to CollectPrintJob, whose own
# polling is bounded; any still here a day later are dropped too.
module FieldVoices
  class EnrolmentSweepJob < ApplicationJob

    queue_as :default

    DISPATCHED_LIMIT = 1.day

    def perform(now: Time.current)
      expired = FieldVoiceEnrolment.where(status: "previewing").where(expires_at: ..now)
      stale = FieldVoiceEnrolment.where(status: "dispatched").where(updated_at: ...(now - DISPATCHED_LIMIT))
      expired.pluck(:id).each { |id| destroy_if_still(id) { |live| live.status == "previewing" && live.expires_at <= now } }
      stale.pluck(:id).each { |id| destroy_if_still(id) { |live| live.status == "dispatched" && live.updated_at < now - DISPATCHED_LIMIT } }
    end

    private

    # Rechecked on the locked row: a dispatch that began before expiry holds
    # this lock across its send, and once it commits the row is no longer the
    # preview that was selected, so the sweep leaves it alone.
    def destroy_if_still(id)
      FieldVoiceEnrolment.transaction do
        live = FieldVoiceEnrolment.lock.find_by(id:)
        live.destroy! if live && yield(live)
      end
    end

  end
end
