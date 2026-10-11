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
      return unless item.claim_summary!

      # The claim reloaded the item under its lock: these are the words the
      # summary is written from. A correction since then makes it stale.
      revision = item.summary_revision

      summary = begin
        FieldSummaries.summarize(item, inference:)
      rescue UtilityInference::Error
        item.release_summary_claim!
        return
      end
      item.store_summary!(**summary, revision:)
    end

  end
end
