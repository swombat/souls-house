require "test_helper"
require "support/field_tweet_helpers"

class FieldTweetSnapshotTest < ActiveSupport::TestCase

  include FieldTweetHelpers

  setup do
    @account = accounts(:personal_account)
    enable_field_tweets
  end

  test "one refresh time drives UTC daily counts and the one-hour backlog label without changing worker state" do
    before_midnight = Time.utc(2026, 10, 16, 23, 59, 59)
    travel_to before_midnight do
      source = @account.create_field_tweet_source!(handle: "example", window_since: before_midnight - 30.minutes)
      @account.field_tweets.create!(provider_tweet_id: "123456", author_handle: "example",
        text: "Snapshot clock fixture", posted_at: before_midnight, fetched_at: before_midnight,
        url: "https://x.com/example/status/123456")

      first = FieldItems.tweet_stream_json(@account, now: before_midnight)
      assert_equal before_midnight.iso8601, first[:refreshed_at]
      assert_equal "syncing", first.dig(:source, :state)
      assert_equal 1, first.dig(:source, :imported_today)

      # Request a later snapshot without advancing the process clock. Both
      # calculations must use the same explicit refresh time.
      later = before_midnight + 31.minutes
      refreshed = FieldItems.tweet_stream_json(@account, now: later)
      assert_equal later.iso8601, refreshed[:refreshed_at]
      assert_equal "backlogged", refreshed.dig(:source, :state)
      assert_equal 0, refreshed.dig(:source, :imported_today)
      assert_equal "active", source.reload.state
      assert_nil source.last_success_at
      assert_equal source.checkpoint_at.iso8601, refreshed.dig(:source, :collected_through)

      source.update!(state_reason: "Waiting for allowance")
      assert_equal "waiting", FieldItems.tweet_stream_json(@account, now: later).dig(:source, :state)
      assert_equal "Waiting for allowance", source.reload.state_reason
    end
  end

  test "no-source snapshots have a timestamp and feature-off stays absent" do
    now = Time.utc(2026, 10, 17)
    snapshot = FieldItems.tweet_stream_json(@account, now:)
    assert_equal now.iso8601, snapshot[:refreshed_at]
    assert_nil snapshot[:source]
    Setting.instance.update!(field_tweets_enabled: false)
    assert_nil FieldItems.tweet_stream_json(@account, now:)
  end

end
