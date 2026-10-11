require "test_helper"
require "webmock/minitest"

# X is stubbed throughout; nothing here reaches api.x.com.
class XPosterTest < ActiveSupport::TestCase

  TWEETS_URL = "https://api.x.com/2/tweets".freeze
  TOKEN_URL = "https://api.x.com/2/oauth2/token".freeze

  setup do
    @agent = agents(:research_assistant)
    @integration = XIntegration.create!(
      account: @agent.account, enabled: true, x_username: "househandle",
      access_token: "live-token", refresh_token: "refresh-1", token_expires_at: 2.hours.from_now
    )
  end

  test "posts once and records the tweet" do
    stub = stub_x_post(id: "1001")

    result = post!("Hello from the house", key: "k1")

    assert_not result.replayed
    assert_equal "posted", result.log.status
    assert_equal "1001", result.log.tweet_id
    assert_equal "https://x.com/househandle/status/1001", result.log.url
    assert_requested stub, times: 1
    assert_requested :post, TWEETS_URL, headers: { "Authorization" => "Bearer live-token" }, body: { text: "Hello from the house" }.to_json
  end

  test "a reply carries the in_reply_to id" do
    stub_x_post(id: "1002")

    post!("A reply", key: "k1", reply_to: "999")

    assert_requested :post, TWEETS_URL, body: { text: "A reply", reply: { in_reply_to_tweet_id: "999" } }.to_json
  end

  test "the same key returns the stored post and never calls X again" do
    stub = stub_x_post(id: "1003")

    post!("Once", key: "same")
    replay = post!("Once", key: "same")

    assert replay.replayed
    assert_equal "1003", replay.log.tweet_id
    assert_requested stub, times: 1
    assert_equal 1, TweetLog.count
  end

  test "a key reused for different text is refused" do
    stub_x_post(id: "1004")
    post!("First", key: "same")

    error = assert_raises(XPoster::Refused) { post!("Second", key: "same") }
    assert_equal "idempotency_key_reused", error.code
  end

  test "posting switched off refuses before anything is sent" do
    @integration.update!(enabled: false)

    error = assert_raises(XPoster::Refused) { post!("Hello", key: "k1") }
    assert_equal "posting_disabled", error.code
    assert_not_requested :post, TWEETS_URL
    assert_equal 0, TweetLog.count
  end

  test "an account with no connection is refused" do
    @integration.destroy!

    error = assert_raises(XPoster::Refused) { post!("Hello", key: "k1") }
    assert_equal "not_connected", error.code
  end

  test "the resident's own account is used, never another account's handle" do
    other = agents(:other_account_agent)
    assert_not_equal other.account, @agent.account

    error = assert_raises(XPoster::Refused) { XPoster.new(agent: other).post!(text: "Hi", idempotency_key: "k1") }
    assert_equal "not_connected", error.code
    assert_not_requested :post, TWEETS_URL
  end

  test "the daily ceiling counts posted, pending and unknown posts but not definite failures" do
    @integration.update!(daily_post_limit: 3)
    create_log(status: "posted", tweet_id: "1")
    create_log(status: "outcome_unknown")
    create_log(status: "failed")
    create_log(status: "posted", tweet_id: "2", created_at: 25.hours.ago)
    stub_x_post(id: "1005")

    post!("Third", key: "k3")
    error = assert_raises(XPoster::Refused) { post!("Fourth", key: "k4") }

    assert_equal "daily_limit_reached", error.code
    assert_equal :too_many_requests, error.http_status
  end

  test "over-length text by X's weighted count is refused before reserving" do
    error = assert_raises(XPoster::Refused) { post!("字" * 141, key: "k1") }
    assert_equal "text_too_long", error.code
    assert_equal 0, TweetLog.count
  end

  test "a missing idempotency key is refused" do
    error = assert_raises(XPoster::Refused) { post!("Hello", key: nil) }
    assert_equal "idempotency_key_required", error.code
  end

  test "a timeout after sending is outcome_unknown and a retry with the same key does not resend" do
    stub = stub_request(:post, TWEETS_URL).to_raise(Net::ReadTimeout)

    first = post!("Maybe", key: "k1")
    replay = post!("Maybe", key: "k1")

    assert_equal "outcome_unknown", first.log.status
    assert replay.replayed
    assert_equal "outcome_unknown", replay.log.status
    assert_requested stub, times: 1
  end

  test "a connection reset while waiting for the answer is outcome_unknown" do
    stub_request(:post, TWEETS_URL).to_raise(Errno::ECONNRESET)

    assert_equal "outcome_unknown", post!("A", key: "k1").log.status
  end

  test "a 5xx and an unreadable 2xx are outcome_unknown, not failures" do
    stub_request(:post, TWEETS_URL).to_return(status: 503, body: "")
    assert_equal "outcome_unknown", post!("A", key: "k1").log.status

    WebMock.reset!
    stub_request(:post, TWEETS_URL).to_return(status: 201, body: "not json")
    assert_equal "outcome_unknown", post!("B", key: "k2").log.status
  end

  test "a 2xx whose JSON is the wrong shape is outcome_unknown, never a crash or a stranded pending post" do
    [ "null", "42", "[]", { data: [] }.to_json, { data: 42 }.to_json, { data: { id: 123 } }.to_json, { data: { id: "abc" } }.to_json ].each_with_index do |body, index|
      WebMock.reset!
      stub_request(:post, TWEETS_URL).to_return(status: 201, body:)

      log = post!("Shape #{index}", key: "shape-#{index}").log
      assert_equal "outcome_unknown", log.status, "body #{body}"
    end
  end

  test "error bodies of any JSON shape still produce a definite failure" do
    [ "null", "42", "[]", { errors: "nope" }.to_json, { errors: [ "x", 1, nil, { message: "real" } ] }.to_json, { title: 5 }.to_json ].each_with_index do |body, index|
      WebMock.reset!
      stub_request(:post, TWEETS_URL).to_return(status: 403, body:)

      log = post!("Error #{index}", key: "error-#{index}").log
      assert_equal "failed", log.status, "body #{body}"
      assert_equal "forbidden", log.failure_reason
    end
    assert_includes TweetLog.find_by(idempotency_key: "error-4").error_message, "real"
  end

  test "a failure to record X's answer after it accepted leaves the post unknown" do
    stub_x_post(id: "2001")

    poster = XPoster.new(agent: @agent)
    poster.define_singleton_method(:record_response!) { |_log, _response| raise NoMethodError, "boom" }
    log = poster.post!(text: "Accepted", idempotency_key: "k1").log

    assert_equal "outcome_unknown", log.status
    assert_requested :post, TWEETS_URL, times: 1
  end

  test "a post interrupted after reserving stays pending, replays without sending, and becomes resolvable once quiet" do
    log = create_log(status: "pending")
    log.update_columns(idempotency_key: "k1", request_digest: Digest::SHA256.hexdigest({ text: "t", reply_to: nil }.to_json))

    replay = post!("t", key: "k1")
    assert replay.replayed
    assert_equal "pending", replay.log.status
    assert_not_requested :post, TWEETS_URL

    assert_raises(ArgumentError) { log.resolve!(resolution: "not_posted", by: @agent) }

    travel TweetLog::PENDING_RESOLVABLE_AFTER + 1.minute do
      log.reload.resolve!(resolution: "not_posted", by: @agent)
    end
    assert_equal "resolved_not_posted", log.reload.status
  end

  test "a post resolved while it waited to send is never sent" do
    stub_x_post(id: "2002")
    poster = XPoster.new(agent: @agent)
    poster.define_singleton_method(:reserve!) do |text:, idempotency_key:, reply_to:|
      log = super(text:, idempotency_key:, reply_to:)
      log.first.update_columns(status: "resolved_not_posted")
      log
    end

    log = poster.post!(text: "Too late", idempotency_key: "k1").log

    assert_equal "resolved_not_posted", log.status
    assert_not_requested :post, TWEETS_URL
  end

  test "a resolution in the gap after the token step and before the send stops the send" do
    stub_x_post(id: "2003")
    poster = XPoster.new(agent: @agent)
    agent = @agent
    test_case = self
    poster.define_singleton_method(:refreshed_access_token) do |log|
      token = super(log)
      test_case.travel(TweetLog::PENDING_RESOLVABLE_AFTER + 1.minute) { log.reload.resolve!(resolution: "not_posted", by: agent) }
      token
    end

    log = poster.post!(text: "Gap", idempotency_key: "k1").log

    assert_equal "resolved_not_posted", log.status
    assert_not_requested :post, TWEETS_URL
  end

  test "a refused connection is a definite failure that does not count toward the ceiling" do
    unreachable = Object.new
    %i[use_ssl= open_timeout= read_timeout= write_timeout= max_retries=].each { |name| unreachable.define_singleton_method(name) { |_| nil } }
    unreachable.define_singleton_method(:start) { raise Errno::ECONNREFUSED }
    unreachable.define_singleton_method(:started?) { false }

    log = Net::HTTP.stub(:new, unreachable) { post!("A", key: "k1") }.log

    assert_equal "failed", log.status
    assert_equal "unreachable", log.failure_reason
    assert_equal 0, @integration.tweet_logs.counting_toward_limit.count
  end

  test "X's 401, 403 and 429 become clear failure reasons" do
    { 401 => "unauthorized", 403 => "forbidden", 429 => "rate_limited" }.each_with_index do |(code, reason), index|
      WebMock.reset!
      stub_request(:post, TWEETS_URL).to_return(
        status: code, body: { title: "Problem", detail: "detail #{code}" }.to_json,
        headers: { "x-rate-limit-reset" => 1.hour.from_now.to_i.to_s }
      )
      log = post!("Post #{index}", key: "k#{index}").log
      assert_equal "failed", log.status
      assert_equal reason, log.failure_reason
      assert_includes log.error_message, "detail #{code}"
    end
  end

  test "a stale token is refreshed first, the new token is used, and the rotated refresh token is kept" do
    @integration.update!(token_expires_at: 1.minute.from_now)
    refresh = stub_request(:post, TOKEN_URL)
      .with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "refresh-1"))
      .to_return(status: 200, body: { access_token: "fresh-token", refresh_token: "refresh-2", expires_in: 7200 }.to_json)
    stub_x_post(id: "1006")

    with_x_credentials { post!("Fresh", key: "k1") }

    assert_requested refresh, times: 1
    assert_requested :post, TWEETS_URL, headers: { "Authorization" => "Bearer fresh-token" }
    assert_equal "refresh-2", @integration.reload.refresh_token
  end

  test "a failed refresh marks the post failed and sends nothing" do
    @integration.update!(token_expires_at: 1.minute.from_now)
    stub_request(:post, TOKEN_URL).to_return(status: 400, body: "{}")

    log = with_x_credentials { post!("Stale", key: "k1") }.log

    assert_equal "failed", log.status
    assert_equal "token_refresh_failed", log.failure_reason
    assert_not_requested :post, TWEETS_URL
  end

  test "an unknown post can be resolved either way, and only once" do
    log = create_log(status: "outcome_unknown")

    log.resolve!(resolution: "posted", tweet_id: "4242", by: @agent)
    assert_equal "resolved_posted", log.reload.status
    assert_equal "4242", log.tweet_id

    assert_raises(ArgumentError) { log.resolve!(resolution: "not_posted", by: @agent) }
  end

  private

  def post!(text, key:, reply_to: nil)
    XPoster.new(agent: @agent).post!(text:, idempotency_key: key, reply_to:)
  end

  def stub_x_post(id:)
    stub_request(:post, TWEETS_URL).to_return(
      status: 201, body: { data: { id:, text: "x" } }.to_json, headers: { "Content-Type" => "application/json" }
    )
  end

  def create_log(status:, tweet_id: nil, created_at: Time.current)
    @integration.tweet_logs.create!(agent: @agent, text: "t", status:, tweet_id:, created_at:)
  end

  def with_x_credentials(&block)
    credentials = Rails.application.credentials
    original = credentials.method(:dig)
    credentials.stub(:dig, ->(*keys) { keys.first == :x ? { client_id: "cid", client_secret: "csecret" }[keys.last] : original.call(*keys) }, &block)
  end

end
