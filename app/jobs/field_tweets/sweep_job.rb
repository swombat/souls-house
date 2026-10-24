module FieldTweets
  # Queues a run for every active stream whose next attempt is due. Runs
  # claim their source, so an overlap with a slow run is harmless.
  class SweepJob < ApplicationJob

    queue_as :default

    def perform
      return unless FieldTweets.enabled?

      FieldTweets::Sync.due.limit(500).pluck(:id).each { |id| FieldTweets::SyncJob.perform_later(id) }
    end

  end
end
