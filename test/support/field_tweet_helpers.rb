# A fake TwitterAPI.io for tweet stream tests: answers search calls from a
# script of pages (or errors) and records every query and cursor it was
# asked for. Nothing leaves the test.
module FieldTweetHelpers

  class FakeClient

    attr_reader :calls, :keys

    def initialize(*responses)
      @responses = responses
      @calls = []
      @keys = []
    end

    def factory
      ->(key) { @keys << key; self }
    end

    def push(*responses) = @responses.concat(responses)

    def search(query, cursor: nil)
      @calls << { query: query, cursor: cursor }
      response = @responses.shift
      raise "FakeClient: no response scripted for call #{@calls.size}" if response.nil?
      raise response if response.is_a?(Exception)

      response
    end

  end

  def tweet_payload(id, at:, handle: "danielt", text: "Post #{id}", **extra)
    {
      "type" => "tweet", "id" => id.to_s, "url" => "https://x.com/#{handle}/status/#{id}", "text" => text,
      "createdAt" => at.utc.strftime("%a %b %d %H:%M:%S +0000 %Y"),
      "likeCount" => 3, "retweetCount" => 1, "replyCount" => 0, "quoteCount" => 0, "viewCount" => 40,
      "isReply" => false, "conversationId" => id.to_s,
      "author" => { "type" => "user", "userName" => handle, "id" => "4242", "name" => "Daniel" }
    }.merge(extra.transform_keys(&:to_s))
  end

  def page_of(tweets, cursor: nil)
    TwitterApiIo::Page.new(tweets: tweets, next_cursor: cursor, has_next_page: cursor.present?)
  end

  def enable_field_tweets(site: "10", account: "1", cap: 50)
    Setting.instance.update!(field_tweets_enabled: true, field_tweets_site_monthly_usd_ceiling: site,
      field_tweets_account_monthly_usd_ceiling: account, field_tweets_daily_import_cap: cap, field_tweets_poll_minutes: 15,
      field_tweets_house_halted_at: nil, field_tweets_house_halt_reason: nil)
  end

  # The account's own TwitterAPI.io integration, made directly (the adapter's
  # network check is tested on its own).
  def connect_twitterapi_io(account, key = "own-key-123", user: users(:user_1))
    connection = account.service_connections.new(provider: "twitterapi_io", management_scope: "account_managed",
      credential_kind: "api_key", status: "connected", connected_by_user: user, label: "TwitterAPI.io",
      credential_fingerprint: SecureRandom.hex(16), credential_metadata: {})
    connection.credential_payload_hash = { "api_key" => key }
    connection.save!
    connection
  end

  def with_house_key(key = "house-test-key", &block)
    FieldTweets.stub(:house_key, key, &block)
  end

  def run_sync(source, client)
    FieldTweets::Sync.new(source, client: client.factory).call
  end

end
