require "test_helper"
require "support/field_tweet_helpers"

# Inline tweet cards (JdwnWj): reading post links out of messages, one shared
# fetch per post, failure states, and the open conversation being told.
class TweetEmbedTest < ActiveSupport::TestCase

  include FieldTweetHelpers
  include ActionCable::TestHelper

  # A fake /twitter/tweets: answers from a script, records the ids asked for.
  class FakeLookup

    attr_reader :calls

    def initialize(*responses)
      @responses = responses
      @calls = []
    end

    def factory = ->(_key) { self }

    def tweets(ids)
      @calls << ids
      response = @responses.shift
      raise "FakeLookup: nothing scripted for call #{@calls.size}" if response.nil?
      raise response if response.is_a?(Exception)

      response
    end

  end

  EXAMPLE_ID = "2116625402898841824"
  TWEET_JOBS = [ TweetEmbedSyncJob, TweetEmbedFetchJob ].freeze

  setup do
    @agent = agents(:research_assistant)
    @chat = @agent.account.chats.create!(title: "Links", model_id: "openrouter/auto", agents: [ @agent ])
    @previous_factory = TweetEmbedFetchJob.client_factory
  end

  teardown { TweetEmbedFetchJob.client_factory = @previous_factory }

  def example_tweet(id = EXAMPLE_ID, **extra)
    tweet_payload(id, at: Time.utc(2026, 10, 30, 9), handle: "JoshuaSWarren", text: "Plain text, <b>not html</b>", **extra)
  end

  def with_lookup(lookup, key: "house-test-key", &block)
    TweetEmbedFetchJob.client_factory = lookup.factory
    with_house_key(key, &block)
  end

  def post(content, role: "user", **attrs)
    attrs[:user] ||= users(:confirmed_user) if role == "user"
    attrs[:agent] ||= @agent if role == "assistant"
    @chat.messages.create!(role: role, content: content, **attrs)
  end

  # --- reading links ---

  test "x.com and twitter.com status links in every common form give the numeric id" do
    [
      "https://x.com/JoshuaSWarren/status/#{EXAMPLE_ID}",
      "https://twitter.com/JoshuaSWarren/status/#{EXAMPLE_ID}?s=20&t=abc",
      "http://www.x.com/JoshuaSWarren/status/#{EXAMPLE_ID}/",
      "https://mobile.twitter.com/JoshuaSWarren/status/#{EXAMPLE_ID}#frag",
      "https://X.COM/JoshuaSWarren/status/#{EXAMPLE_ID}/photo/1",
      "https://x.com/i/web/status/#{EXAMPLE_ID}",
      "https://x.com/i/status/#{EXAMPLE_ID}",
      "https://x.com/JoshuaSWarren/status/#{EXAMPLE_ID}."
    ].each { assert_equal EXAMPLE_ID, TweetEmbed.status_id_from(it), it }
  end

  test "anything that isn't an X post on an allowlisted host is not read" do
    [
      "https://x.com/JoshuaSWarren",
      "https://evilx.com/a/status/#{EXAMPLE_ID}",
      "https://x.com.evil.example/a/status/#{EXAMPLE_ID}",
      "https://nitter.net/a/status/#{EXAMPLE_ID}",
      "ftp://x.com/a/status/#{EXAMPLE_ID}",
      "https://x.com/a/status/notanumber",
      "https://x.com/a/likes/#{EXAMPLE_ID}"
    ].each { assert_nil TweetEmbed.status_id_from(it), it }
  end

  test "a message's links are read once each, in order, at most three, never from code" do
    content = <<~TEXT
      first https://x.com/a/status/3 and again https://twitter.com/a/status/3?s=1
      `https://x.com/a/status/9` then (https://x.com/b/status/1) and https://x.com/c/status/2
      ```
      https://x.com/d/status/8
      ```
      and https://x.com/e/status/4
    TEXT
    assert_equal %w[3 1 2], TweetEmbed.status_ids_in(content)
  end

  test "tilde fences are code too" do
    assert_equal %w[2], TweetEmbed.status_ids_in("~~~\nhttps://x.com/a/status/1\n~~~\nhttps://x.com/a/status/2")
  end

  # --- linking and fetching ---

  test "a posted link becomes a card once fetched, with escaped-as-text content and only twimg media" do
    lookup = FakeLookup.new([ example_tweet(EXAMPLE_ID, "extendedEntities" => { "media" => [
      { "type" => "photo", "media_url_https" => "https://pbs.twimg.com/media/a.jpg" },
      { "type" => "photo", "media_url_https" => "https://tracker.example/b.jpg" }
    ] }) ])
    message = nil
    with_lookup(lookup) do
      perform_enqueued_jobs(only: TWEET_JOBS) { message = post("look https://x.com/JoshuaSWarren/status/#{EXAMPLE_ID}?s=20") }
    end

    assert_equal [ [ EXAMPLE_ID ] ], lookup.calls
    card = message.reload.tweet_embeds_json.sole
    assert_equal EXAMPLE_ID, card[:id]
    assert_equal "JoshuaSWarren", card[:author_handle]
    assert_equal "Plain text, <b>not html</b>", card[:text]
    assert_equal "https://x.com/JoshuaSWarren/status/#{EXAMPLE_ID}", card[:url]
    assert_equal [ "https://pbs.twimg.com/media/a.jpg" ], card[:media].map { it["url"] }
    assert_nil card[:quoted]
    assert_equal 1, message.as_json["tweet_embeds_json"].length
  end

  test "a text-only post without media or quote fields still makes a card" do
    bare = { "id" => EXAMPLE_ID, "text" => "Just words", "createdAt" => "Fri Oct 30 09:00:00 +0000 2026",
             "author" => { "userName" => "JoshuaSWarren" } }
    message = nil
    with_lookup(FakeLookup.new([ bare ])) do
      perform_enqueued_jobs(only: TWEET_JOBS) { message = post("https://x.com/JoshuaSWarren/status/#{EXAMPLE_ID}") }
    end
    card = message.reload.tweet_embeds_json.sole
    assert_equal [ "Just words", [] ], [ card[:text], card[:media] ]
    assert_nil card[:author_name]
  end

  test "a quoted post comes with the card" do
    tweet = example_tweet(EXAMPLE_ID, "quoted_tweet" => { "id" => "77", "text" => "the original", "author" => { "userName" => "someone" } })
    message = nil
    with_lookup(FakeLookup.new([ tweet ])) do
      perform_enqueued_jobs(only: TWEET_JOBS) { message = post("https://x.com/JoshuaSWarren/status/#{EXAMPLE_ID}") }
    end
    assert_equal({ "id" => "77", "author_handle" => "someone", "text" => "the original" }, message.reload.tweet_embeds_json.sole[:quoted])
  end

  test "the same post linked in two conversations and twice in one is fetched once for the house" do
    other_chat = @agent.account.chats.create!(title: "Elsewhere", model_id: "openrouter/auto", agents: [ @agent ])
    lookup = FakeLookup.new([ example_tweet ])
    with_lookup(lookup) do
      perform_enqueued_jobs(only: TWEET_JOBS) do
        post("https://x.com/a/status/#{EXAMPLE_ID} https://twitter.com/a/status/#{EXAMPLE_ID}")
        other_chat.messages.create!(role: "user", user: users(:confirmed_user), content: "https://x.com/i/web/status/#{EXAMPLE_ID}")
      end
    end
    assert_equal 1, lookup.calls.size
    assert_equal 1, TweetEmbed.count
    assert_equal 2, MessageTweetEmbed.count
  end

  test "concurrent fetches of one post: only the claimant calls the provider" do
    embed = TweetEmbed.for_status_id!(EXAMPLE_ID)
    assert embed.claim!
    assert_not TweetEmbed.find(embed.id).claim!, "a second worker must not take a live claim"

    lookup = FakeLookup.new
    with_lookup(lookup) { TweetEmbedFetchJob.perform_now(embed.id) }
    assert_empty lookup.calls

    travel TweetEmbed::CLAIM_TTL + 1.second do
      assert TweetEmbed.find(embed.id).claim!, "a stale claim (a crashed worker) can be taken over"
    end
  end

  test "losing the race to create the shared row, inside a transaction, ends with one row and a usable transaction" do
    first = TweetEmbed.for_status_id!(EXAMPLE_ID)
    lookups = 0
    real_find_by = TweetEmbed.method(:find_by)
    # The first lookup misses (the other worker hasn't committed yet), so the
    # insert runs and hits the unique index.
    racing_find_by = ->(*args, **kw) { (lookups += 1) == 1 ? nil : real_find_by.call(*args, **kw) }
    TweetEmbed.transaction do
      TweetEmbed.stub(:find_by, racing_find_by) do
        assert_equal first, TweetEmbed.for_status_id!(EXAMPLE_ID)
      end
      assert_equal 1, TweetEmbed.count, "the outer transaction still works after the lost insert"
    end
  end

  # --- failures ---

  test "a post the provider doesn't return is remembered as missing and never asked for again" do
    lookup = FakeLookup.new([])
    message = nil
    with_lookup(lookup) do
      perform_enqueued_jobs(only: TWEET_JOBS) { message = post("gone https://x.com/a/status/#{EXAMPLE_ID}") }
      perform_enqueued_jobs(only: TWEET_JOBS) { post("again https://x.com/a/status/#{EXAMPLE_ID}") }
    end
    assert_equal 1, lookup.calls.size
    assert_equal "missing", TweetEmbed.sole.state
    assert_empty message.reload.tweet_embeds_json
    assert_includes message.content, "https://x.com/a/status/#{EXAMPLE_ID}", "the link itself stays in the text"
  end

  test "a transient failure retries later and gives up after the limit, without a card" do
    lookup = FakeLookup.new(*Array.new(TweetEmbed::MAX_ATTEMPTS) { TwitterApiIo::Error.new("TwitterAPI.io answered 503", status: 503) })
    embed = TweetEmbed.for_status_id!(EXAMPLE_ID)
    with_lookup(lookup) do
      TweetEmbedFetchJob.perform_now(embed.id)
      embed.reload
      assert_equal [ "pending", 1 ], [ embed.state, embed.attempts ]
      assert embed.next_attempt_at > Time.current
      assert_enqueued_with(job: TweetEmbedFetchJob, args: [ embed.id ])

      TweetEmbedFetchJob.perform_now(embed.id)
      assert_equal 1, lookup.calls.size, "not due yet: no second call"

      (TweetEmbed::MAX_ATTEMPTS - 1).times do
        travel_to(embed.reload.next_attempt_at + 1.second) { TweetEmbedFetchJob.perform_now(embed.id) }
      end
    end
    embed.reload
    assert_equal [ "failed", TweetEmbed::MAX_ATTEMPTS, nil ], [ embed.state, embed.attempts, embed.card_json ]
    assert_equal TweetEmbed::MAX_ATTEMPTS, lookup.calls.size
  end

  test "without a house key nothing is called or counted" do
    embed = TweetEmbed.for_status_id!(EXAMPLE_ID)
    lookup = FakeLookup.new
    with_lookup(lookup, key: nil) { TweetEmbedFetchJob.perform_now(embed.id) }
    assert_empty lookup.calls
    embed.reload
    assert_equal [ "pending", 0, nil ], [ embed.state, embed.attempts, embed.claimed_at ]
  end

  # --- when links are read ---

  test "a streamed reply is read when it stops streaming, not while its chunks arrive" do
    reply = nil
    lookup = FakeLookup.new([ example_tweet ])
    with_lookup(lookup) do
      perform_enqueued_jobs(only: TWEET_JOBS) do
        reply = post("", role: "assistant")
        reply.stream_content("see https://x.com/JoshuaSWarren/sta")
        reply.stream_content("tus/#{EXAMPLE_ID} for it")
        assert_empty lookup.calls
        reply.stop_streaming
      end
    end
    assert_equal [ [ EXAMPLE_ID ] ], lookup.calls
    assert_equal EXAMPLE_ID, reply.reload.tweet_embeds_json.sole[:id]
  end

  test "an edit that removes the link removes the card, and adding one adds it" do
    message = nil
    with_lookup(FakeLookup.new([ example_tweet ], [ example_tweet("55") ])) do
      perform_enqueued_jobs(only: TWEET_JOBS) { message = post("https://x.com/a/status/#{EXAMPLE_ID}") }
      perform_enqueued_jobs(only: TWEET_JOBS) { message.update!(content: "no link now, but https://x.com/b/status/55") }
    end
    assert_equal [ "55" ], message.reload.tweet_embeds_json.map { it[:id] }
    assert TweetEmbed.exists?(provider_tweet_id: EXAMPLE_ID), "the shared row stays for other messages"
  end

  test "a message without post links enqueues nothing" do
    assert_no_enqueued_jobs(only: TweetEmbedSyncJob) { post("https://example.com/status/1 and words") }
  end

  test "a sync job that runs after the message started streaming again reads nothing" do
    reply = post("see https://x.com/a/status/#{EXAMPLE_ID}", role: "assistant")
    reply.update_columns(streaming: true, content: "half https://x.com/a/status/99")
    assert_no_enqueued_jobs(only: TweetEmbedFetchJob) { TweetEmbedSyncJob.perform_now(reply.id) }
    assert_empty reply.reload.message_tweet_embeds
    assert_equal 0, TweetEmbed.count
  end

  test "sync jobs for one message read its current text, not the text they were queued for" do
    message = post("first https://x.com/a/status/11")
    message.update!(content: "now https://x.com/a/status/22")
    # Two jobs are queued (one per save); whichever runs, each reads the row
    # under its lock as it is now.
    assert_enqueued_jobs 2, only: TweetEmbedSyncJob
    2.times { TweetEmbedSyncJob.perform_now(message.id) }
    assert_equal [ "22" ], message.reload.message_tweet_embeds.map { it.tweet_embed.provider_tweet_id }
  end

  # --- arriving in an open conversation ---

  test "the open conversation is told when a card lands, and app clients get a revision" do
    message = post("https://x.com/a/status/#{EXAMPLE_ID}")
    TweetEmbedSyncJob.perform_now(message.id)
    revision = message.reload.revision

    with_lookup(FakeLookup.new([ example_tweet ])) do
      assert_broadcasts("Chat:#{@chat.obfuscated_id}", 1) do
        TweetEmbedFetchJob.perform_now(TweetEmbed.sole.id)
      end
    end
    assert_operator message.reload.revision, :>, revision
  end

  test "a post already cached shows its card under a new message at once" do
    with_lookup(FakeLookup.new([ example_tweet ])) do
      perform_enqueued_jobs(only: TWEET_JOBS) { post("https://x.com/a/status/#{EXAMPLE_ID}") }
    end
    message = post("same one https://x.com/a/status/#{EXAMPLE_ID}")
    assert_broadcasts("Chat:#{@chat.obfuscated_id}", 1) do
      assert_no_enqueued_jobs(only: TweetEmbedFetchJob) { TweetEmbedSyncJob.perform_now(message.id) }
    end
    assert_equal 1, message.reload.tweet_embeds_json.size
  end

  test "a fetch that lands while a message is being linked still refreshes the conversation" do
    embed = TweetEmbed.for_status_id!(EXAMPLE_ID)
    stale = TweetEmbed.find(embed.id)
    message = post("https://x.com/a/status/#{EXAMPLE_ID}")
    # The fetch finishes (and announces to messages already linked: none)
    # after this sync read the row as pending.
    embed.record_fetched!(example_tweet)
    TweetEmbed.stub(:for_status_id!, stale) do
      assert_equal "pending", stale.state
      assert_broadcasts("Chat:#{@chat.obfuscated_id}", 1) do
        assert_no_enqueued_jobs(only: TweetEmbedFetchJob) { TweetEmbedSyncJob.perform_now(message.id) }
      end
    end
    assert_equal 1, message.reload.tweet_embeds_json.size
  end

  test "the app-sync announcement is made only once the revision it names is written" do
    message = post("https://x.com/a/status/#{EXAMPLE_ID}")
    TweetEmbedSyncJob.perform_now(message.id)
    seen = []
    stream = Message::Revisioned.stream_name(@chat.id)
    record = ->(name, data) { seen << [ data[:latest_revision], Message.where(id: message.id).pick(:revision) ] if name == stream }
    with_lookup(FakeLookup.new([ example_tweet ])) do
      ActionCable.server.stub(:broadcast, record) { TweetEmbedFetchJob.perform_now(TweetEmbed.sole.id) }
    end
    announced, stored = seen.sole
    assert_equal announced, stored, "the row must already hold the announced revision when the announcement goes out"
    assert_equal announced, message.reload.revision
  end

  test "the shared card says nothing about who linked it" do
    with_lookup(FakeLookup.new([ example_tweet ])) do
      perform_enqueued_jobs(only: TWEET_JOBS) { post("https://x.com/a/status/#{EXAMPLE_ID}") }
    end
    card = TweetEmbed.sole.card_json
    assert_empty card.keys.map(&:to_s) & %w[message_id chat_id conversation_id account_id messages]
    assert_not TweetEmbed.column_names.any? { it.match?(/message|chat|account|user/) }
  end

end
