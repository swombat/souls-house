module FieldTweets
  # Settings are mutable, even when tweet collection is off or no source exists.
  # Members receive only their account's derived, content-free invalidation.
  class RefreshSettingsJob < ApplicationJob

    def perform
      return unless Setting.instance.allow_agents?

      Account.enabled.select(:id).find_in_batches do |accounts|
        FieldTweetStream.refresh!(accounts)
      end
    end

  end
end
