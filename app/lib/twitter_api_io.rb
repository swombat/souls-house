require "net/http"
require "json"

# TwitterAPI.io, read-only: the one search call tweet streams use.
#
# Monitoring follows the provider's own advice (docs, checked 2026-10-11):
# /twitter/tweet/advanced_search with queryType=Latest over a bounded
# `from:handle since_time:… until_time:…` window, paged by its opaque
# next_cursor. Not /twitter/user/last_tweets, whose cursor is opaque and which
# the docs warn against for frequent monitoring.
#
# Pricing (twitterapi.io/pricing, 2026-10-11): $0.15 per 1,000 returned
# tweets, at least $0.00015 per call. A page holds at most 20.
class TwitterApiIo

  BASE = "https://api.twitterapi.io"
  SEARCH_PATH = "/twitter/tweet/advanced_search"
  PAGE_SIZE = 20
  USD_PER_TWEET = BigDecimal("0.00015")
  MIN_USD_PER_CALL = BigDecimal("0.00015")
  TIMEOUT = 20

  class Error < StandardError

    attr_reader :status

    def initialize(message, status: nil)
      super(message)
      @status = status
    end

    # The key or its balance: retrying won't help, a person must act.
    def funding? = [ 401, 402, 403 ].include?(status)
    # Worth another try later: rate limits, the provider's own failures, the
    # network, an answer that couldn't be read.
    def transient? = status.nil? || status == 429 || status >= 500 || answered_ok?
    # A 2xx whose body couldn't be read: the provider may have billed for
    # tweets nobody saw, so what it cost is unknown, not known to be zero.
    def answered_ok? = status.present? && (200..299).cover?(status)

  end

  Page = Data.define(:tweets, :next_cursor, :has_next_page)

  def self.charge_for(returned) = [ USD_PER_TWEET * returned.to_i, MIN_USD_PER_CALL ].max

  # The most a page can cost: what is reserved before asking.
  def self.page_reserve = charge_for(PAGE_SIZE)

  def initialize(api_key)
    raise ArgumentError, "an API key is needed" if api_key.blank?

    @api_key = api_key
  end

  def search(query, cursor: nil)
    params = { query: query, queryType: "Latest" }
    params[:cursor] = cursor if cursor.present?
    uri = URI(BASE + SEARCH_PATH)
    uri.query = URI.encode_www_form(params)

    request = Net::HTTP::Get.new(uri)
    request["X-API-Key"] = @api_key
    request["Accept"] = "application/json"
    response = build_http(uri).start { |http| http.request(request) }

    status = response.code.to_i
    # Never the body: it may echo the request, and the request carries the key.
    raise Error.new("TwitterAPI.io answered #{status}", status: status) unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    raise Error.new("TwitterAPI.io answered without a tweet list", status: status) unless data.is_a?(Hash) && data["tweets"].is_a?(Array)

    Page.new(tweets: data["tweets"], next_cursor: data["next_cursor"].presence, has_next_page: data["has_next_page"] == true)
  rescue JSON::ParserError
    raise Error.new("TwitterAPI.io answered with something that isn't JSON", status: status)
  rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError, IOError => e
    raise Error.new("Couldn't reach TwitterAPI.io (#{e.class.name})")
  end

  # Net::HTTP retries an idempotent GET once by itself when a connection
  # drops. A search is billed, so that retry would be a second paid call
  # under one reservation: every retry goes through FieldTweets.reserve!.
  def build_http(uri)
    http = Net::HTTP.new(uri.hostname, uri.port)
    http.use_ssl = true
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT
    http.max_retries = 0
    http
  end

  # "from:handle since_time:… until_time:…" plus what the source wants. The
  # query, not a filter afterwards, decides replies, quotes and reposts, so
  # the house doesn't pay for tweets it then throws away.
  def self.window_query(handle:, since:, until_time:, replies:, quotes:, reposts:)
    parts = [ "from:#{handle}", "since_time:#{since.to_i}", "until_time:#{until_time.to_i}" ]
    parts << "-filter:replies" unless replies
    parts << "-filter:quote" unless quotes
    parts << "include:nativeretweets" if reposts
    parts.join(" ")
  end

end
