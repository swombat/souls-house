# Hourly: queue a summary for every readable Field file and recording that
# doesn't have one yet (first run: everything brought in before summaries
# existed). Bounded per run; the next run picks up the rest.
module FieldItems
  class SummarySweepJob < ApplicationJob

    queue_as :default

    BATCH = 200

    def perform
      return unless FieldSummaries.enabled?

      [ FieldFile, FieldRecording ].each do |model|
        model.summary_due.order(:id).limit(BATCH).each { |item| SummarizeJob.perform_later(item) }
      end
    end

  end
end
