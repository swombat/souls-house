# A public post brought into an account's Field by a tweet stream
# (FieldTweetSource): a snapshot of the post as it was fetched, not a mirror.
# Edits and deletions on X after the fetch are not followed.
#
# Deleting discards. The row stays, and with it the unique (account, tweet
# id) pair, so a later search that returns the same tweet can't bring it
# back; restoring it undiscards the same row.
class FieldTweet < ApplicationRecord

  include Discard::Model
  include Broadcastable
  include ObfuscatesId
  include SyncAuthorizable
  include FieldTaggable

  MAX_TEXT = 30_000
  MAX_MEDIA = 4
  MAX_RELATED_TEXT = 1_000
  HANDLE = /\A[A-Za-z0-9_]{1,15}\z/
  METRICS = { "likeCount" => "likes", "retweetCount" => "reposts", "replyCount" => "replies",
              "quoteCount" => "quotes", "viewCount" => "views", "bookmarkCount" => "bookmarks" }.freeze

  belongs_to :account
  belongs_to :field_tweet_source, optional: true

  validates :provider_tweet_id, presence: true, format: { with: /\A\d{1,32}\z/ }
  validates :author_handle, format: { with: HANDLE }
  validates :text, length: { maximum: MAX_TEXT }
  validates :posted_at, :fetched_at, :url, presence: true

  broadcasts_to :account

  scope :newest_first, -> { order(posted_at: :desc, id: :desc) }

  def title = "@#{author_handle}: #{text.to_s.squish.truncate(80)}"

  # "post", "reply", "quote", "repost": what the card calls it. A reply may
  # also quote; the flags carry both, this names the first.
  def kinds
    list = []
    list << "repost" if is_repost
    list << "reply" if is_reply
    list << "quote" if is_quote
    list.presence || [ "post" ]
  end

  class Invalid < StandardError; end

  # Normalised, bounded attributes from one provider tweet (advanced_search
  # shape). Only what the Field shows and searches; the payload itself is
  # not kept. Raises Invalid for a tweet that lacks an id, author or time.
  def self.attributes_from(tweet, fetched_at:)
    raise Invalid, "not a tweet" unless tweet.is_a?(Hash)

    id = tweet["id"].to_s
    author = tweet["author"].is_a?(Hash) ? tweet["author"] : {}
    handle = author["userName"].to_s
    posted_at = parse_time(tweet["createdAt"])
    raise Invalid, "tweet without an id" unless id.match?(/\A\d{1,32}\z/)
    raise Invalid, "tweet #{id} without a usable author" unless handle.match?(HANDLE)
    raise Invalid, "tweet #{id} without a time" unless posted_at

    reposted = tweet["retweeted_tweet"].is_a?(Hash) ? tweet["retweeted_tweet"] : nil
    quoted = tweet["quoted_tweet"].is_a?(Hash) ? tweet["quoted_tweet"] : nil

    {
      provider_tweet_id: id,
      author_id: author["id"].to_s.presence&.first(32),
      author_handle: handle,
      author_name: author["name"].to_s.presence&.first(100),
      text: tweet["text"].to_s.scrub("").delete("\u0000").first(MAX_TEXT),
      posted_at: posted_at,
      fetched_at: fetched_at,
      url: "https://x.com/#{handle}/status/#{id}",
      is_reply: tweet["isReply"] == true || tweet["inReplyToId"].present?,
      is_quote: quoted.present?,
      is_repost: reposted.present?,
      in_reply_to_tweet_id: digits(tweet["inReplyToId"]),
      in_reply_to_handle: tweet["inReplyToUsername"].to_s.then { it.match?(HANDLE) ? it : nil },
      conversation_id: digits(tweet["conversationId"]),
      quoted_tweet_id: digits(quoted&.dig("id")),
      reposted_tweet_id: digits(reposted&.dig("id")),
      media: media_from(tweet),
      metrics: METRICS.each_with_object({}) { |(from, to), memo| memo[to] = tweet[from].to_i if tweet[from].is_a?(Numeric) },
      metrics_at: fetched_at,
      related: related_from(quoted || reposted),
      lang: tweet["lang"].to_s.first(16).presence
    }
  end

  def self.parse_time(value)
    return nil if value.blank?

    # The provider's createdAt is Twitter's "Tue Dec 10 07:00:30 +0000 2024".
    Time.strptime(value.to_s, "%a %b %d %H:%M:%S %z %Y").utc
  rescue ArgumentError
    Time.iso8601(value.to_s).utc rescue nil
  end

  def self.digits(value)
    value.to_s.match?(/\A\d{1,32}\z/) ? value.to_s : nil
  end

  def self.media_from(tweet)
    list = tweet.dig("extendedEntities", "media") || tweet.dig("extended_entities", "media") || tweet["media"]
    return [] unless list.is_a?(Array)

    list.first(MAX_MEDIA).filter_map do |item|
      next unless item.is_a?(Hash)

      url = (item["media_url_https"] || item["url"]).to_s
      next unless url.start_with?("https://") && url.length <= 500

      { "type" => item["type"].to_s.first(20).presence || "photo", "url" => url,
        "alt" => item["ext_alt_text"].to_s.first(500).presence }.compact
    end
  end

  def self.related_from(tweet)
    return {} unless tweet.is_a?(Hash)

    handle = tweet.dig("author", "userName").to_s
    {
      "id" => digits(tweet["id"]),
      "author_handle" => (handle if handle.match?(HANDLE)),
      "text" => tweet["text"].to_s.scrub("").delete("\u0000").first(MAX_RELATED_TEXT).presence
    }.compact
  end

end
