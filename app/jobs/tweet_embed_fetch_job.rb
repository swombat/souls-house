# Fetches one post for its card, at most once at a time (TweetEmbed#claim!),
# and tells every open conversation that links it when the card is ready.
class TweetEmbedFetchJob < ApplicationJob

  queue_as :default

  # client: ->(api_key) { an object with #tweets(ids) }; tests pass a fake.
  mattr_accessor :client_factory, default: ->(key) { TwitterApiIo.new(key) }

  def perform(tweet_embed_id)
    embed = TweetEmbed.find_by(id: tweet_embed_id) or return
    return unless embed.claim!

    key = FieldTweets.live ? FieldTweets.house_key : nil
    # No key to ask with: nothing is spent and nothing is counted. The link
    # stays a link; a later mention tries again.
    return embed.release! if key.blank?

    begin
      tweet = client_factory.call(key).tweets([ embed.provider_tweet_id ])
        .find { it["id"].to_s == embed.provider_tweet_id }
    rescue TwitterApiIo::Error => e
      retry_at = embed.record_transient_failure!(e)
      self.class.set(wait_until: retry_at).perform_later(embed.id) if retry_at
      return
    end

    if tweet
      embed.record_fetched!(tweet)
    else
      embed.record_missing!
    end
    announce(embed) if embed.state == "fetched"
  end

  private

  def announce(embed)
    Message.kept.where(id: embed.message_tweet_embeds.select(:message_id)).includes(:chat).find_each(&:tweet_card_arrived!)
  end

end
