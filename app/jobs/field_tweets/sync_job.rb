module FieldTweets
  # One collection run for one tweet stream (FieldTweets::Sync).
  class SyncJob < ApplicationJob

    queue_as :default

    def perform(source_id)
      source = FieldTweetSource.find_by(id: source_id)
      return unless source && FieldTweets.enabled?

      FieldTweets::Sync.new(source).call
    end

  end
end
