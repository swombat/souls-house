# One check thirty minutes after an explicit human recording correction.
# Renames/deletes affecting many recordings never queue this job. A live call
# gets one further check after its claim can expire; no unbounded polling.
module FieldItems
  class RefreshSummaryJob < SummarizeJob

    def perform(item, recheck: false, inference: UtilityInference)
      return unless FieldSummaries.enabled?

      claim = item.claim_stale_summary!
      if claim == :waiting
        item.enqueue_authorized_summary_check
      elsif claim == :busy
        self.class.set(wait: FieldSummarizable::CLAIM_TTL + 1.second).perform_later(item, recheck: true) unless recheck
      elsif claim
        write_summary(item, claim:, inference:)
      end
    end

  end
end
