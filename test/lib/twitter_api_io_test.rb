require "test_helper"
require "webmock/minitest"

class TwitterApiIoTest < ActiveSupport::TestCase

  SEARCH = "https://api.twitterapi.io/twitter/tweet/advanced_search"

  test "search sends the key in the header, the window query and the cursor" do
    stub = stub_request(:get, SEARCH)
      .with(query: { query: "from:danielt since_time:1 until_time:2", queryType: "Latest", cursor: "abc" },
            headers: { "X-API-Key" => "k-123" })
      .to_return(status: 200, body: { tweets: [ { id: "1" } ], has_next_page: true, next_cursor: "def" }.to_json)

    page = TwitterApiIo.new("k-123").search("from:danielt since_time:1 until_time:2", cursor: "abc")
    assert_requested stub
    assert_equal [ { "id" => "1" } ], page.tweets
    assert_equal [ "def", true ], [ page.next_cursor, page.has_next_page ]
  end

  test "errors say the status and never repeat the body or the key" do
    stub_request(:get, /advanced_search/).to_return(status: 401, body: { error: 401, message: "bad key k-123" }.to_json)
    error = assert_raises(TwitterApiIo::Error) { TwitterApiIo.new("k-123").search("from:x") }
    assert_equal 401, error.status
    assert error.funding?
    assert_not error.transient?
    assert_not_includes error.message, "k-123"

    stub_request(:get, /advanced_search/).to_return(status: 429)
    assert TwitterApiIo.new("k").then { |c| assert_raises(TwitterApiIo::Error) { c.search("q") } }.transient?

    stub_request(:get, /advanced_search/).to_timeout
    error = assert_raises(TwitterApiIo::Error) { TwitterApiIo.new("k").search("q") }
    assert_nil error.status
    assert error.transient?
  end

  test "Net::HTTP never retries a billed search by itself" do
    http = TwitterApiIo.new("k").send(:build_http, URI(SEARCH))
    assert_equal 0, http.max_retries
    assert http.use_ssl?
  end

  test "a 200 that can't be read is an answered error: its cost is unknown" do
    stub_request(:get, /advanced_search/).to_return(status: 200, body: "<html>")
    error = assert_raises(TwitterApiIo::Error) { TwitterApiIo.new("k").search("q") }
    assert_equal 200, error.status
    assert error.answered_ok?
    assert error.transient?
    assert_not error.funding?
  end

  test "a page costs $0.15 per thousand returned, at least $0.00015" do
    assert_equal BigDecimal("0.00015"), TwitterApiIo.charge_for(0)
    assert_equal BigDecimal("0.00015"), TwitterApiIo.charge_for(1)
    assert_equal BigDecimal("0.003"), TwitterApiIo.charge_for(20)
    assert_equal BigDecimal("0.003"), TwitterApiIo.page_reserve
  end

end
