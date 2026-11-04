# Reads a message's post links and fetches the ones the house hasn't yet.
class TweetEmbedSyncJob < ApplicationJob

  queue_as :default
  discard_on ActiveJob::DeserializationError

  def perform(message_id)
    message = Message.find_by(id: message_id) or return

    message.sync_tweet_embeds!.each { TweetEmbedFetchJob.perform_later(it.id) }
  end

end
