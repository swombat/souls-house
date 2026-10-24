# Writes one Field item's two summaries (FieldSummaries). Queued when its words
# become readable (text extracted, transcript ready) and by the hourly
# SummarySweepJob for anything that was missed or failed. The claim is taken
# before the call and counts as an attempt, so duplicates never call twice and
# a failing item stops after FieldSummarizable::MAX_ATTEMPTS.
module FieldItems
  class SummarizeJob < ApplicationJob

    queue_as :default

    discard_on ActiveJob::DeserializationError

    def perform(item, inference: UtilityInference)
      return unless FieldSummaries.enabled?
      claim = item.claim_summary!
      return unless claim

      write_summary(item, claim:, inference:)
    end

    def write_summary(item, claim:, inference: UtilityInference)
      summary = begin
        FieldSummaries.summarize(item, inference:)
      rescue UtilityInference::Error
        item.release_summary_claim!(claim:)
        return
      end
      item.store_summary!(**summary, claim:)
    end

  end
end
