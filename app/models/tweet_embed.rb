# One X post, fetched once for the whole house so a conversation can show it
# as a card under the message that linked it (JdwnWj). Messages point here
# through MessageTweetEmbed; this row holds no reference back, so it can't
# say which conversations linked the post.
#
# Lifecycle: pending → fetched (a card) | missing (the provider answered and
# has no such post: never asked again) | failed (gave up after MAX_ATTEMPTS
# transient failures). A transient failure stays pending with a later
# next_attempt_at. Until a row is fetched the message shows only its link.
#
# Who pays: the house's TwitterAPI.io key (Daniel, jXkbke: "accept the API
# cost"), at most one call per post ever, since the id is unique and a fetch
# is claimed before it is made.
class TweetEmbed < ApplicationRecord

  STATES = %w[pending fetched missing failed].freeze
  MAX_PER_MESSAGE = 3
  MAX_ATTEMPTS = 5
  CLAIM_TTL = 5.minutes
  MEDIA_HOSTS = %w[pbs.twimg.com video.twimg.com].freeze

  # x.com and twitter.com, with or without www. / mobile.; status paths only.
  HOSTS = %w[x.com twitter.com].flat_map { [ it, "www.#{it}", "mobile.#{it}" ] }.freeze
  STATUS_PATH = %r{\A/(?:[A-Za-z0-9_]{1,15}|i(?:/web)?)/status(?:es)?/(\d{1,32})(?:/|\z)}
  URL_IN_TEXT = %r{https?://[^\s<>()\[\]"'`]+}i

  has_many :message_tweet_embeds, dependent: :restrict_with_exception

  validates :provider_tweet_id, presence: true, format: { with: /\A\d{1,32}\z/ }
  validates :state, inclusion: { in: STATES }

  scope :due, ->(now = Time.current) {
    where(state: "pending").where("next_attempt_at IS NULL OR next_attempt_at <= ?", now)
  }

  # The status id of an x.com / twitter.com post link, or nil. Anything else
  # (other hosts, profile pages, look-alike hosts) is not a post.
  def self.status_id_from(url)
    uri = URI.parse(url.to_s.sub(/[.,;:!?]+\z/, ""))
    return nil unless uri.is_a?(URI::HTTP) && uri.host
    return nil unless HOSTS.include?(uri.host.downcase)

    uri.path.to_s.match(STATUS_PATH)&.[](1)
  rescue URI::InvalidURIError
    nil
  end

  # Distinct status ids linked in a message's text, first appearance first,
  # at most MAX_PER_MESSAGE. Links in fenced code (``` or ~~~) and inline
  # code are text, not links. Indented code blocks are not detected.
  def self.status_ids_in(content)
    text = content.to_s.gsub(/^ {0,3}(```|~~~).*?(^ {0,3}\1|\z)/m, " ").gsub(/`[^`\n]*`/, " ")
    text.scan(URL_IN_TEXT).filter_map { status_id_from(it) }.uniq.first(MAX_PER_MESSAGE)
  end

  # The shared row for an id, made once even when two messages race to it.
  # The insert sits in a savepoint so losing the race inside a caller's
  # transaction doesn't abort it.
  def self.for_status_id!(id)
    find_by(provider_tweet_id: id) || transaction(requires_new: true) { create!(provider_tweet_id: id) }
  rescue ActiveRecord::RecordNotUnique
    find_by!(provider_tweet_id: id)
  end

  # Take the right to fetch, atomically: one worker per row, and never for a
  # row that isn't due. => true when this caller holds it.
  def claim!(now: Time.current)
    claimed = self.class.due(now).where(id: id)
      .where("claimed_at IS NULL OR claimed_at < ?", now - CLAIM_TTL)
      .update_all(claimed_at: now, updated_at: now)
    reload if claimed == 1
    claimed == 1
  end

  # Record the provider's tweet hash (the /twitter/tweets shape, the same as
  # advanced_search). Normalised by FieldTweet.attributes_from so a card and
  # the Field read a post the same way.
  def record_fetched!(tweet, now: Time.current)
    attrs = FieldTweet.attributes_from(tweet, fetched_at: now)
    update!(
      state: "fetched", claimed_at: nil, last_error: nil, next_attempt_at: nil,
      attempts: attempts + 1,
      author_handle: attrs[:author_handle], author_name: attrs[:author_name],
      text: attrs[:text].to_s.first(FieldTweet::MAX_TEXT), posted_at: attrs[:posted_at], url: attrs[:url],
      media: self.class.safe_media(attrs[:media]), related: attrs[:related] || {},
      is_quote: attrs[:is_quote], is_reply: attrs[:is_reply], fetched_at: now
    )
  rescue FieldTweet::Invalid => e
    record_missing!(now: now, reason: e.message)
  end

  def record_missing!(now: Time.current, reason: "TwitterAPI.io has no such post")
    update!(state: "missing", claimed_at: nil, attempts: attempts + 1, next_attempt_at: nil,
      last_error: reason.to_s.first(200), fetched_at: now)
  end

  # A failure worth another try: back off, and give up after MAX_ATTEMPTS.
  # => the time of the next try, or nil when it has given up.
  def record_transient_failure!(error, now: Time.current)
    tries = attempts + 1
    if tries >= MAX_ATTEMPTS
      update!(state: "failed", claimed_at: nil, attempts: tries, next_attempt_at: nil, last_error: error.to_s.first(200))
      nil
    else
      retry_at = now + (2**tries).minutes
      update!(claimed_at: nil, attempts: tries, next_attempt_at: retry_at, last_error: error.to_s.first(200))
      retry_at
    end
  end

  # Let go of a claim without counting an attempt (no key to ask with).
  def release!
    update_columns(claimed_at: nil)
  end

  def self.safe_media(list)
    Array(list).filter_map do |item|
      url = item["url"].to_s
      host = (URI.parse(url).host rescue nil)
      next unless url.start_with?("https://") && MEDIA_HOSTS.include?(host)

      item.slice("type", "url", "alt")
    end
  end

  # What a card shows. Only fetched rows have one; the text is plain text and
  # the client renders it as text, never as HTML.
  def card_json
    return nil unless state == "fetched"

    {
      id: provider_tweet_id, url: url, author_handle: author_handle, author_name: author_name,
      text: text, posted_at: posted_at&.iso8601, media: media, is_reply: is_reply,
      quoted: (related.presence if is_quote)
    }.compact
  end

end
