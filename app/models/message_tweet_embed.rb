# A message's link to a shared TweetEmbed: what puts a tweet card under it.
class MessageTweetEmbed < ApplicationRecord

  belongs_to :message
  belongs_to :tweet_embed

end
