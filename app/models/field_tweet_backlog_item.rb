# A tweet a search returned that waits for the account's import allowance
# (FieldTweets.daily_import_cap). Holds the normalised attributes
# FieldTweet.attributes_from gave, so importing it later needs no new call.
class FieldTweetBacklogItem < ApplicationRecord

  belongs_to :field_tweet_source

  scope :oldest_first, -> { order(:posted_at, :id) }

end
