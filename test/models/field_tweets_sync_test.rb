require "test_helper"
require "support/field_tweet_helpers"

# Tweet stream collection (FieldTweets::Sync) against a fake provider.
class FieldTweetsSyncTest < ActiveSupport::TestCase

  include FieldTweetHelpers

  setup do
    @account = agents(:research_assistant).account
    @connected = Time.utc(2026, 10, 11, 12, 0)
    travel_to @connected
    enable_field_tweets
    @account.update!(field_tweets_house_key: true)
    accounts(:another_team).update!(field_tweets_house_key: true)
    @source = @account.create_field_tweet_source!(handle: "@danielt", created_by: users(:user_1))
  end

  teardown { travel_back }

  test "a new stream starts at connection and asks for own posts, replies and quotes, not reposts" do
    assert_equal "danielt", @source.handle
    assert_equal @connected, @source.checkpoint_at

    travel 15.minutes
    client = FakeClient.new(page_of([ tweet_payload(101, at: @connected + 5.minutes) ]))
    with_house_key { assert_equal :done, run_sync(@source, client) }

    query = client.calls.sole[:query]
    assert_equal "from:danielt since_time:#{@connected.to_i} until_time:#{(Time.current - 60).to_i}", query
    assert_equal [ "house-test-key" ], client.keys

    tweet = @account.field_tweets.sole
    assert_equal "101", tweet.provider_tweet_id
    assert_equal @connected + 5.minutes, tweet.posted_at
    assert_equal "https://x.com/danielt/status/101", tweet.url
    assert_equal({ "likes" => 3, "reposts" => 1, "replies" => 0, "quotes" => 0, "views" => 40 }, tweet.metrics)

    @source.reload
    assert_equal Time.current - 60, @source.checkpoint_at
    assert_not @source.window_open?
    assert_equal Time.current + 15.minutes, @source.next_attempt_at

    call = FieldTweetCall.sole
    assert_equal [ "settled", "house", 1, 0, 1 ], [ call.status, call.funding, call.returned_count, call.already_stored_count, call.queued_count ]
    assert_equal BigDecimal("0.00015"), call.charge_usd
  end

  test "the source's choices go into the query, not a filter afterwards" do
    @source.update!(include_replies: false, include_quotes: false, include_reposts: true)
    assert_equal "from:danielt since_time:1 until_time:2 -filter:replies -filter:quote include:nativeretweets",
      @source.query_for(Time.at(1), Time.at(2))
  end

  test "changing what is included restarts an open window's paging under the new query" do
    @source.update!(window_since: @connected, window_until: @connected + 10.minutes, window_cursor: "c5", window_pages: 3)
    @source.update!(include_reposts: true)
    assert_equal [ nil, 0 ], [ @source.window_cursor, @source.window_pages ]
    assert @source.window_open?
  end

  test "nothing is asked for until a window of at least a minute has passed" do
    travel 30.seconds
    client = FakeClient.new
    with_house_key { assert_equal :done, run_sync(@source, client) }
    assert_empty client.calls
  end

  test "more than twenty results: the checkpoint moves only after the last page" do
    travel 15.minutes
    first = (1..20).map { |n| tweet_payload(200 + n, at: @connected + n.seconds) }
    client = FakeClient.new(page_of(first, cursor: "c2"), page_of([ tweet_payload(300, at: @connected + 1.second) ]))
    with_house_key { run_sync(@source, client) }

    assert_equal [ nil, "c2" ], client.calls.map { it[:cursor] }
    assert_equal 1, client.calls.map { it[:query] }.uniq.size, "both pages search the same frozen window"
    assert_equal 21, @account.field_tweets.count
    assert_equal Time.current - 60, @source.reload.checkpoint_at
    assert_equal [ 20, 1 ], FieldTweetCall.order(:id).pluck(:returned_count)
  end

  test "a failure midway through paging keeps the cursor and the checkpoint, and resumes there" do
    travel 15.minutes
    window_until = Time.current - 60
    client = FakeClient.new(page_of([ tweet_payload(1, at: @connected + 1.minute) ], cursor: "c2"),
      TwitterApiIo::Error.new("TwitterAPI.io answered 503", status: 503))
    with_house_key { assert_equal :failed, run_sync(@source, client) }

    @source.reload
    assert_equal @connected, @source.checkpoint_at, "a failure never moves the checkpoint"
    assert_equal "c2", @source.window_cursor
    assert_equal 1, @source.failure_count
    assert_equal Time.current + 15.minutes, @source.next_attempt_at
    assert_equal "waiting", @source.display_state
    failed = FieldTweetCall.order(:id).last
    assert_equal [ "failed", 503, BigDecimal("0.00015") ], [ failed.status, failed.http_status, failed.charge_usd ]

    travel 20.minutes
    # The resumed window, then the one that has opened since.
    client.push(page_of([ tweet_payload(2, at: @connected + 30.seconds) ]), page_of([]))
    with_house_key { assert_equal :done, run_sync(@source, client) }
    resumed, caught_up = client.calls.last(2)
    assert_equal "c2", resumed[:cursor]
    assert_includes resumed[:query], "until_time:#{window_until.to_i}", "the frozen window is resumed, not replaced"
    assert_includes caught_up[:query], "since_time:#{(window_until - FieldTweets::Sync::OVERLAP).to_i}"
    @source.reload
    assert_equal Time.current - 60, @source.checkpoint_at
    assert_equal 0, @source.failure_count
    assert_equal %w[1 2], @account.field_tweets.order(:provider_tweet_id).pluck(:provider_tweet_id)
  end

  test "repeated failures back off and then ask for a person" do
    travel 15.minutes
    errors = Array.new(FieldTweets::Sync::MAX_FAILURES) { TwitterApiIo::Error.new("no answer") }
    client = FakeClient.new(*errors)
    gaps = []
    FieldTweets::Sync::MAX_FAILURES.times do
      travel_to([ @source.reload.next_attempt_at, Time.current ].max + 1.second)
      with_house_key { run_sync(@source, client) }
      gaps << (@source.reload.next_attempt_at - Time.current).round
    end
    assert_equal "needs_attention", @source.state
    assert_match(/Stopped after 8 failures/, @source.state_reason)
    assert_equal [ 15, 30, 60, 120, 240 ].map { it * 60 }, gaps.first(5)
    assert_equal "uncertain", FieldTweetCall.order(:id).last.status, "no answer: the reservation is kept"
  end

  test "a crash after inserting but before the checkpoint leaves neither, and the page is fetched again" do
    travel 15.minutes
    client = FakeClient.new(page_of([ tweet_payload(7, at: @connected + 1.minute) ]))
    sync = FieldTweets::Sync.new(@source, client: client.factory)
    sync.stub(:complete_window!, -> { raise "power cut" }) do
      with_house_key { assert_raises(RuntimeError) { sync.call } }
    end
    @source.reload
    assert_equal @connected, @source.checkpoint_at
    assert_empty @source.backlog_items
    assert_empty @account.field_tweets
    assert_nil @source.sync_claimed_at, "the claim is released even after a crash"
    assert_equal "reserved", FieldTweetCall.sole.status, "a reserved call keeps counting against the ceiling"

    client.push(page_of([ tweet_payload(7, at: @connected + 1.minute) ]))
    with_house_key { run_sync(@source, client) }
    assert_equal [ "7" ], @account.field_tweets.pluck(:provider_tweet_id)
  end

  test "overlap and reordering: tweets already kept are counted, not imported twice" do
    travel 15.minutes
    client = FakeClient.new(page_of([ tweet_payload(1, at: @connected + 1.minute) ]))
    with_house_key { run_sync(@source, client) }

    travel 15.minutes
    since = @source.reload.checkpoint_at - FieldTweets::Sync::OVERLAP
    client.push(page_of([ tweet_payload(3, at: Time.current - 2.minutes), tweet_payload(1, at: @connected + 1.minute),
      tweet_payload(2, at: @source.checkpoint_at - 3.minutes), tweet_payload(3, at: Time.current - 2.minutes) ]))
    with_house_key { run_sync(@source, client) }

    assert_includes client.calls.last[:query], "since_time:#{since.to_i}", "the window reaches back by the overlap"
    assert_equal %w[1 2 3], @account.field_tweets.order(:provider_tweet_id).pluck(:provider_tweet_id)
    call = FieldTweetCall.order(:id).last
    assert_equal [ 4, 2, 2 ], [ call.returned_count, call.already_stored_count, call.queued_count ]
  end

  test "a deleted tweet stays deleted when the stream returns it again" do
    travel 15.minutes
    client = FakeClient.new(page_of([ tweet_payload(5, at: @connected + 1.minute) ]))
    with_house_key { run_sync(@source, client) }
    @account.field_tweets.sole.discard!

    travel 15.minutes
    client.push(page_of([ tweet_payload(5, at: @connected + 1.minute) ]))
    with_house_key { run_sync(@source, client) }
    assert_empty @account.field_tweets.kept
    assert_equal 1, FieldTweetCall.order(:id).last.already_stored_count

    @account.field_tweets.sole.undiscard!
    assert_equal [ "5" ], @account.field_tweets.kept.pluck(:provider_tweet_id)
  end

  test "over the day's allowance tweets wait in the backlog; no new page is paid for until they are in" do
    enable_field_tweets(cap: 2)
    travel 15.minutes
    client = FakeClient.new(page_of((1..3).map { tweet_payload(it, at: @connected + it.minutes) }, cursor: "c2"))
    with_house_key { assert_equal :waiting, run_sync(@source, client) }

    assert_equal %w[1 2], @account.field_tweets.order(:posted_at).pluck(:provider_tweet_id), "oldest first"
    assert_equal [ "3" ], @source.backlog_items.pluck(:provider_tweet_id)
    @source.reload
    assert_equal "c2", @source.window_cursor, "the window waits with its cursor"
    assert_equal @connected, @source.checkpoint_at
    assert_match(/allowance/, @source.state_reason)
    assert_equal "waiting", @source.status_json[:state]
    assert_equal 1, @source.status_json[:backlog]

    travel 2.hours
    with_house_key { run_sync(@source, client) }
    assert_equal 1, client.calls.size, "the same day, nothing more is fetched"

    travel_to Time.utc(2026, 10, 12, 0, 5)
    client.push(page_of([ tweet_payload(4, at: @connected + 4.minutes) ]), page_of([]))
    with_house_key { run_sync(@source, client) }
    assert_equal %w[1 2 3 4], @account.field_tweets.order(:posted_at).pluck(:provider_tweet_id)
    assert_equal "c2", client.calls[1][:cursor], "the backlog went in first, then the window went on"
    assert_empty @source.backlog_items
  end

  test "an allowance used up exactly stops paid pages; the window waits with its cursor" do
    enable_field_tweets(cap: 1)
    travel 15.minutes
    client = FakeClient.new(page_of([ tweet_payload(1, at: @connected + 1.minute) ], cursor: "c2"))
    with_house_key { assert_equal :waiting, run_sync(@source, client) }
    assert_equal 1, client.calls.size, "no second page is bought for tweets that couldn't come in today"
    assert_empty @source.backlog_items
    @source.reload
    assert_equal [ "c2", @connected ], [ @source.window_cursor, @source.checkpoint_at ]

    travel_to Time.utc(2026, 10, 12, 0, 5)
    client.push(page_of([]), page_of([]))
    with_house_key { run_sync(@source, client) }
    assert_equal "c2", client.calls[1][:cursor]
  end

  test "more results without a usable cursor keeps the window open and counts as a failure" do
    travel 15.minutes
    [ [ nil, [ tweet_payload(1, at: @connected + 1.minute) ] ], [ "", [ tweet_payload(1, at: @connected + 1.minute) ] ] ].each do |cursor, tweets|
      client = FakeClient.new(TwitterApiIo::Page.new(tweets: tweets, next_cursor: cursor, has_next_page: true))
      with_house_key { assert_equal :failed, run_sync(@source, client) }
      @source.reload
      assert_equal @connected, @source.checkpoint_at, "the checkpoint doesn't move over unread results"
      assert @source.window_open?
      assert_match(/no usable cursor/, @source.state_reason)
      travel_to @source.next_attempt_at + 1.second
    end
    assert_equal 2, @source.failure_count
    assert_equal [ "1" ], @account.field_tweets.pluck(:provider_tweet_id), "what the page did return is kept"
  end

  test "a cursor that repeats, or an empty page that claims more, is a broken continuation too" do
    travel 15.minutes
    client = FakeClient.new(page_of([ tweet_payload(1, at: @connected + 1.minute) ], cursor: "c2"),
      page_of([ tweet_payload(2, at: @connected + 30.seconds) ], cursor: "c2"))
    with_house_key { assert_equal :failed, run_sync(@source, client) }
    assert_equal [ "c2", @connected ], [ @source.reload.window_cursor, @source.checkpoint_at ]

    travel_to @source.next_attempt_at + 1.second
    client.push(TwitterApiIo::Page.new(tweets: [], next_cursor: "c3", has_next_page: true))
    with_house_key { assert_equal :failed, run_sync(@source, client) }
    assert_equal [ "c2", 2 ], [ @source.reload.window_cursor, @source.failure_count ]
  end

  test "an unreadable returned tweet is counted apart and its window kept as a gap" do
    travel 15.minutes
    window_until = Time.current - 60
    broken = tweet_payload(2, at: @connected).merge("createdAt" => nil)
    client = FakeClient.new(page_of([ tweet_payload(1, at: @connected + 1.minute), broken ]))
    with_house_key { run_sync(@source, client) }

    call = FieldTweetCall.sole
    assert_equal [ 2, 0, 1, 1 ], [ call.returned_count, call.already_stored_count, call.queued_count, call.rejected_count ]
    @source.reload
    assert_equal [ @connected, window_until ], [ @source.gap_since, @source.gap_until ], "the window isn't certified as collected"
    assert_equal 0, @source.window_rejected
    assert_equal [ "1" ], @account.field_tweets.pluck(:provider_tweet_id)
  end

  test "an unreadable success keeps its whole reservation, and the window waits" do
    travel 15.minutes
    client = FakeClient.new(TwitterApiIo::Error.new("TwitterAPI.io answered with something that isn't JSON", status: 200))
    with_house_key { assert_equal :failed, run_sync(@source, client) }
    call = FieldTweetCall.sole
    assert_equal [ "uncertain", 200, BigDecimal("0.003") ], [ call.status, call.http_status, call.charge_usd ]
    @source.reload
    assert_equal [ @connected, 1 ], [ @source.checkpoint_at, @source.failure_count ]
    assert_equal "active", @source.state
  end

  test "a window past its page limit is closed and its unread older end kept as a gap" do
    travel 15.minutes
    stub_const(FieldTweets::Sync, :MAX_WINDOW_PAGES, 2) do
      client = FakeClient.new(page_of([ tweet_payload(1, at: @connected + 9.minutes) ], cursor: "c2"),
        page_of([ tweet_payload(2, at: @connected + 8.minutes) ], cursor: "c3"))
      with_house_key { run_sync(@source, client) }
    end
    @source.reload
    assert_equal [ @connected, @connected + 8.minutes ], [ @source.gap_since, @source.gap_until ]
    assert_equal Time.current - 60, @source.checkpoint_at
    assert_equal({ since: @connected.iso8601, until: (@connected + 8.minutes).iso8601 }, @source.status_json[:gap])
  end

  test "a stale cursor restarts the same window from its start" do
    travel 15.minutes
    client = FakeClient.new(page_of([ tweet_payload(1, at: @connected + 1.minute) ], cursor: "old"),
      TwitterApiIo::Error.new("TwitterAPI.io answered 400", status: 400))
    with_house_key { run_sync(@source, client) }
    @source.reload
    assert_nil @source.window_cursor
    assert @source.window_open?

    travel_to @source.next_attempt_at + 1.second
    client.push(page_of([ tweet_payload(1, at: @connected + 1.minute) ]), page_of([]))
    with_house_key { run_sync(@source, client) }
    assert_nil client.calls[2][:cursor]
    assert_includes client.calls[2][:query], "since_time:#{@connected.to_i}", "the same window, from its start"
    assert_equal [ "1" ], @account.field_tweets.pluck(:provider_tweet_id)
    assert_not @source.reload.window_open?
  end

  test "a refused own key stops this stream and never falls back to the house" do
    connect_twitterapi_io(@account)
    travel 15.minutes
    client = FakeClient.new(TwitterApiIo::Error.new("TwitterAPI.io answered 401", status: 401))
    with_house_key { run_sync(@source, client) }

    assert_equal [ "own-key-123" ], client.keys
    @source.reload
    assert_equal "needs_attention", @source.state
    assert_match(/refused the key in this account's TwitterAPI.io integration/, @source.state_reason)
    assert_equal "own", FieldTweetCall.sole.funding
    assert_nil Setting.instance.field_tweets_house_halted_at

    travel 1.hour
    with_house_key { assert_equal :inactive, run_sync(@source, client) }
    assert_equal 1, client.calls.size
  end

  test "an own key collects even while house-paid collection is shut" do
    enable_field_tweets(site: "0")
    @account.update!(field_tweets_house_key: false)
    connect_twitterapi_io(@account)
    travel 15.minutes
    client = FakeClient.new(page_of([]))
    with_house_key(nil) { assert_equal :done, run_sync(@source, client) }
    assert_equal [ "own-key-123" ], client.keys
  end

  test "a refused house key halts every house-paid stream until an admin resumes it" do
    travel 15.minutes
    client = FakeClient.new(TwitterApiIo::Error.new("TwitterAPI.io answered 402", status: 402))
    with_house_key { run_sync(@source, client) }
    assert Setting.instance.field_tweets_house_halted_at
    assert_equal "active", @source.reload.state

    other = accounts(:another_team).create_field_tweet_source!(handle: "someone")
    travel 1.hour
    with_house_key do
      assert_equal :waiting, run_sync(other, client)
      assert_match(/halted/, other.reload.state_reason)
    end
    assert_equal 1, client.calls.size
  end

  test "with house-paid collection not set up, a house stream waits and asks nothing" do
    enable_field_tweets(site: "0")
    travel 15.minutes
    client = FakeClient.new
    with_house_key { assert_equal :waiting, run_sync(@source, client) }
    assert_empty client.calls
    assert_match(/isn't available/, @source.reload.state_reason)
  end

  test "the account's monthly ceiling stops paid calls; the next month starts again" do
    enable_field_tweets(account: "0.003")
    travel 15.minutes
    client = FakeClient.new(page_of([ tweet_payload(1, at: @connected + 1.minute) ], cursor: "c2"))
    with_house_key { assert_equal :waiting, run_sync(@source, client) }
    assert_equal 1, client.calls.size, "the first page settled at $0.00015; another $0.003 reservation would pass $0.003"
    @source.reload
    assert_match(/budget for the month/, @source.state_reason)
    assert_equal Time.utc(2026, 11, 1), @source.next_attempt_at
    assert_equal "c2", @source.window_cursor

    travel_to Time.utc(2026, 11, 1, 0, 1)
    client.push(page_of([]), page_of([]))
    with_house_key { run_sync(@source, client) }
    assert_equal "c2", client.calls[1][:cursor]
  end

  test "reservations respect the house ceiling across accounts" do
    enable_field_tweets(site: "0.005", account: "1")
    other = accounts(:another_team).create_field_tweet_source!(handle: "someone")
    with_house_key do
      FieldTweets.reserve!(@source)
      error = assert_raises(FieldTweets::LimitReached) { FieldTweets.reserve!(other) }
      assert_match(/house's tweet collection budget/, error.message)
    end
  end

  test "one run per stream at a time" do
    travel 15.minutes
    FieldTweetSource.where(id: @source.id).update_all(sync_claimed_at: Time.current - 1.minute)
    client = FakeClient.new
    with_house_key { assert_equal :claimed, run_sync(@source, client) }
    assert_empty client.calls
  end

  test "attributes keep a reply that also quotes, and the quoted tweet, bounded" do
    payload = tweet_payload(9, at: @connected, "isReply" => true, "inReplyToId" => "8", "inReplyToUsername" => "mira",
      "quoted_tweet" => { "id" => "7", "text" => "x" * 5_000, "author" => { "userName" => "lume" } },
      "extendedEntities" => { "media" => Array.new(6) { |n| { "type" => "photo", "media_url_https" => "https://pbs.twimg.com/#{n}.jpg" } } })
    attributes = FieldTweet.attributes_from(payload, fetched_at: @connected)
    assert attributes[:is_reply]
    assert attributes[:is_quote]
    assert_not attributes[:is_repost]
    assert_equal [ "8", "mira", "7" ], attributes.values_at(:in_reply_to_tweet_id, :in_reply_to_handle, :quoted_tweet_id)
    assert_equal 1_000, attributes[:related]["text"].length
    assert_equal "lume", attributes[:related]["author_handle"]
    assert_equal 4, attributes[:media].size

    tweet = @account.field_tweets.create!(attributes)
    assert_equal %w[reply quote], tweet.kinds
  end

  test "a tweet without an id, author or time is refused" do
    assert_raises(FieldTweet::Invalid) { FieldTweet.attributes_from(tweet_payload(1, at: @connected).merge("id" => "abc"), fetched_at: @connected) }
    assert_raises(FieldTweet::Invalid) { FieldTweet.attributes_from(tweet_payload(1, at: @connected).merge("createdAt" => nil), fetched_at: @connected) }
    assert_raises(FieldTweet::Invalid) { FieldTweet.attributes_from(tweet_payload(1, at: @connected, handle: "no spaces"), fetched_at: @connected) }
  end

  test "tweets are searchable and taggable like other Field items, within their account" do
    tweet = @account.field_tweets.create!(FieldTweet.attributes_from(tweet_payload(1, at: @connected, text: "Orchids bloom in October"), fetched_at: @connected))
    accounts(:another_team).field_tweets.create!(FieldTweet.attributes_from(tweet_payload(1, at: @connected, text: "Orchids elsewhere"), fetched_at: @connected))

    results = FieldSearch.new(account: @account, query: "orchids").call.results
    assert_equal [ [ "tweet", tweet.id ] ], results.map { [ it.kind, it.record.id ] }
    assert_equal [ tweet.id ], FieldSearch.new(account: @account, query: "danielt", kinds: [ "tweet" ]).call.results.map { it.record.id }

    tweet.change_tags!(by: users(:user_1), add: [ "flowers" ])
    assert_equal [ tweet.id ], FieldSearch.new(account: @account, tags: [ "flowers" ]).call.results.map { it.record.id }
    assert_equal [ tweet ], FieldListing.new(account: @account, tab: "tweets").records
    assert_equal 1, FieldListing.new(account: @account, tab: "all").counts["tweets"]
  end

  test "what a person sees about a stream never includes the key" do
    connect_twitterapi_io(@account, "secret-key-xyz")
    json = @source.status_json.to_json
    assert_not_includes json, "secret-key-xyz"
    assert_includes json, "\"funding\":\"own\""
    assert_not_includes FieldItems.tweet_stream_json(@account).to_json, "secret-key-xyz"
  end

  # Who pays (Daniel, 2026-10-14): the account's integration, else the house
  # key if a site admin granted it, else nobody.
  test "without an integration or a house grant, nothing is asked and the stream says why" do
    @account.update!(field_tweets_house_key: false)
    travel 15.minutes
    client = FakeClient.new
    with_house_key { assert_equal :waiting, run_sync(@source, client) }
    assert_empty client.calls
    assert_empty FieldTweetCall.all
    assert_equal FieldTweets::NO_FUNDING, @source.reload.state_reason
    assert_nil @source.funding
    with_house_key do
      error = assert_raises(FieldTweets::LimitReached) { FieldTweets.reserve!(@source) }
      assert_equal FieldTweets::NO_FUNDING, error.message
    end
  end

  test "an integration pays before a house grant, and its key is the one sent" do
    connect_twitterapi_io(@account, "account-key")
    travel 15.minutes
    client = FakeClient.new(page_of([]))
    with_house_key { assert_equal :done, run_sync(@source, client) }
    assert_equal [ "account-key" ], client.keys
    assert_equal "own", FieldTweetCall.sole.funding
  end

  test "a disconnected integration no longer pays; the house grant does" do
    connection = connect_twitterapi_io(@account, "account-key")
    connection.update!(status: "revoked", credential_payload: nil)
    travel 15.minutes
    client = FakeClient.new(page_of([]))
    with_house_key { run_sync(@source, client) }
    assert_equal [ "house-test-key" ], client.keys
  end

  test "an integration with no key in it spends nothing and needs attention" do
    connection = connect_twitterapi_io(@account)
    connection.update!(credential_payload: nil)
    travel 15.minutes
    client = FakeClient.new
    with_house_key { assert_equal :failed, run_sync(@source, client) }
    assert_empty client.calls
    assert_equal [ "failed", 0 ], [ FieldTweetCall.sole.status, FieldTweetCall.sole.charge_usd.to_d ]
    assert_equal "needs_attention", @source.reload.state
    assert_nil Setting.instance.field_tweets_house_halted_at
  end

  # Mira, #349 review: a grant revoked while page one is in flight stops page
  # two; the account is read fresh at each reservation.
  test "revoking the house grant mid-run stops the next page" do
    travel 15.minutes
    revoke = Object.new
    first_page = page_of([ tweet_payload(1, at: @connected + 1.minute) ], cursor: "c2")
    revoke.define_singleton_method(:search) do |_query, cursor: nil|
      Account.find(@account_id).update!(field_tweets_house_key: false)
      @page
    end
    revoke.instance_variable_set(:@account_id, @account.id)
    revoke.instance_variable_set(:@page, first_page)
    calls = 0
    factory = ->(_key) { calls += 1; revoke }
    with_house_key { FieldTweets::Sync.new(@source, client: factory).call }
    assert_equal 1, FieldTweetCall.count, "page two must not be reserved after the grant was revoked"
    assert_equal FieldTweets::NO_FUNDING, @source.reload.state_reason
  end

  test "renaming the integration does not restart a stream stopped for its failures" do
    connection = connect_twitterapi_io(@account)
    @source.update!(failure_count: 8)
    @source.needs_attention!("TwitterAPI.io kept failing")
    connection.update!(label: "Our TwitterAPI.io")
    connection.update!(enabled_for_new_agents: true)
    assert_equal [ "needs_attention", 8 ], [ @source.reload.state, @source.failure_count ]

    connection.update!(status: "revoked", credential_payload: nil)
    assert_equal "active", @source.reload.state, "removing the key is a change to who pays"
  end

  test "a paused stream stays paused when the integration changes" do
    @source.pause!("Paused by Daniel")
    connect_twitterapi_io(@account)
    assert_equal "paused", @source.reload.state
  end

  test "disconnecting the integration hands an account with a house grant back to the house" do
    connection = connect_twitterapi_io(@account, "account-key")
    connection.update!(status: "revoked", credential_payload: nil)
    travel 15.minutes
    client = FakeClient.new(page_of([]))
    with_house_key { assert_equal :done, run_sync(@source, client) }
    assert_equal [ "house-test-key" ], client.keys
    assert_equal "house", FieldTweetCall.sole.funding
  end

  test "connecting an integration restarts a stream stopped for its key" do
    connect_twitterapi_io(@account, "bad")
    travel 15.minutes
    with_house_key { run_sync(@source, FakeClient.new(TwitterApiIo::Error.new("TwitterAPI.io answered 402", status: 402))) }
    assert_equal "needs_attention", @source.reload.state

    connect_twitterapi_io(@account, "topped-up")
    assert_equal "active", @source.reload.state
    client = FakeClient.new(page_of([]))
    with_house_key { assert_equal :done, run_sync(@source, client) }
    assert_equal [ "topped-up" ], client.keys
  end

  private

  def stub_const(mod, name, value)
    old = mod.const_get(name)
    mod.send(:remove_const, name)
    mod.const_set(name, value)
    yield
  ensure
    mod.send(:remove_const, name)
    mod.const_set(name, old)
  end

end
