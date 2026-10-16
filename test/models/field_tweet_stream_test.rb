require "test_helper"
require "support/field_tweet_helpers"

class FieldTweetStreamTest < ActiveSupport::TestCase

  include ActionCable::TestHelper
  include FieldTweetHelpers

  self.use_transactional_tests = false

  setup do
    @setting_was = Setting.instance.attributes.select { |name, _| name.start_with?("field_tweets_") }
    @account = Account.create!(name: "Tweet status #{SecureRandom.hex(4)}", account_type: "team")
    @other_account = Account.create!(name: "Tweet isolation #{SecureRandom.hex(4)}", account_type: "team")
    @source = @account.create_field_tweet_source!(handle: "danielt")
    @stream = "FieldTweetStream:#{@account.to_param}"
    @other_stream = "FieldTweetStream:#{@other_account.to_param}"
    @now = Time.current.change(usec: 0)
  end

  teardown do
    [ @account, @other_account ].each { |account| account.reload.destroy! }
    Setting.instance.update_columns(@setting_was)
  end

  test "source creation and destruction carry only the account marker" do
    source = nil
    messages = capture_broadcasts(@other_stream) do
      assert_no_broadcasts(@stream) do
        source = @other_account.create_field_tweet_source!(handle: "privatehandle")
      end
    end
    assert_equal [ { "action" => "refresh" } ], messages
    assert_marker { @source.destroy! }
  end

  test "source allowlist covers every persisted rendered field" do
    {
      handle: "anotherhandle", include_replies: false, include_quotes: false, include_reposts: true,
      own_monthly_usd_limit: "7", state: "paused", state_reason: "SECRET-SENTINEL",
      connected_at: @now - 3.hours, checkpoint_at: @now - 2.hours, window_since: @now - 1.hour,
      gap_since: @now - 4.hours, gap_until: @now - 3.hours, last_success_at: @now,
      next_attempt_at: @now + 15.minutes
    }.each do |column, value|
      assert_marker(column.to_s) { @source.update!(column => value) }
    end
  end

  test "moving a source invalidates both old and new accounts once" do
    messages = capture_broadcasts(@other_stream) do
      assert_equal [ { "action" => "refresh" } ], capture_broadcasts(@stream) {
        @source.update!(account: @other_account)
      }
    end
    assert_equal [ { "action" => "refresh" } ], messages
    assert_no_broadcasts(@stream) do
      assert_equal [ { "action" => "refresh" } ], capture_broadcasts(@other_stream) { @source.destroy! }
    end
  end

  test "hidden bookkeeping attribution touch and no-op writes are quiet" do
    assert_no_broadcasts(@stream) do
      @source.update!(sync_claimed_at: @now, window_cursor: "SECRET-CURSOR", window_pages: 2,
        window_rejected: 3, window_until: @now, failure_count: 4, created_by: users(:user_1))
      @source.touch
      @source.save!
      @source.update!(handle: @source.handle)
      assert_not @source.update(state: "invalid")
    end
  end

  test "later hidden saves touch and reload cannot erase a producing write" do
    assert_marker do
      FieldTweetSource.transaction do
        assert_no_broadcasts(@stream) do
          @source.update!(state_reason: "Waiting")
          @source.update!(failure_count: 1, window_cursor: "hidden")
          @source.touch
          @source.reload.save!
        end
      end
    end
  end

  test "many writes and record instances coalesce for each account at outer commit" do
    assert_marker do
      FieldTweetSource.transaction do
        assert_no_broadcasts(@stream) do
          @source.update!(state_reason: "Waiting")
          FieldTweetSource.find(@source.id).update!(next_attempt_at: @now + 1.hour)
          3.times { |index| create_tweet(100 + index) }
          FieldTweetStream.refresh!([ @account, @account.id ])
        end
      end
    end
  end

  test "outer rollback drops source tweet and explicit markers" do
    assert_no_broadcasts(@stream) do
      FieldTweetSource.transaction do
        @source.update!(state_reason: "Not committed")
        create_tweet(101)
        FieldTweetStream.refresh!(@account)
        raise ActiveRecord::Rollback
      end
    end
    assert_nil @source.reload.state_reason
    assert_not @account.field_tweets.exists?
    assert_marker { @source.update!(state_reason: "Committed later") }
  end

  test "rolled-back source create and destroy lifecycles are quiet" do
    created_id = nil
    assert_no_broadcasts(@other_stream) do
      assert_no_broadcasts(@stream) do
        FieldTweetSource.transaction do
          created_id = @other_account.create_field_tweet_source!(handle: "rollback").id
          @source.destroy!
          raise ActiveRecord::Rollback
        end
      end
    end
    assert_not FieldTweetSource.exists?(created_id)
    assert_predicate @source.reload, :persisted?
  end

  test "savepoint rollback does not emit or poison a later producing write" do
    assert_no_broadcasts(@stream) do
      FieldTweetSource.transaction do
        FieldTweetSource.transaction(requires_new: true) do
          @source.update!(state_reason: "Savepoint only")
          raise ActiveRecord::Rollback
        end
        @source.reload.touch
      end
    end
    assert_marker do
      FieldTweetSource.transaction do
        FieldTweetSource.transaction(requires_new: true) do
          @source.update!(state_reason: "Savepoint rollback")
          raise ActiveRecord::Rollback
        end
        @source.reload.update!(state_reason: "Committed")
      end
    end
  end

  test "savepoint rollback cannot erase an earlier outer marker" do
    assert_marker do
      FieldTweetSource.transaction do
        @source.update!(state_reason: "Outer")
        FieldTweetSource.transaction(requires_new: true) do
          @source.update!(state_reason: "Inner")
          raise ActiveRecord::Rollback
        end
        @source.reload.touch
      end
    end
    assert_equal "Outer", @source.reload.state_reason
  end

  test "committed savepoint waits for outer commit and outer rollback still drops it" do
    assert_marker do
      FieldTweetSource.transaction do
        assert_no_broadcasts(@stream) do
          FieldTweetSource.transaction(requires_new: true) { @source.update!(state_reason: "Committed") }
          @source.touch
        end
      end
    end
    assert_no_broadcasts(@stream) do
      FieldTweetSource.transaction do
        FieldTweetSource.transaction(requires_new: true) { @source.update!(state_reason: "Rolled back") }
        raise ActiveRecord::Rollback
      end
    end
  end

  test "separate committed savepoints can each emit a marker but only after outer commit" do
    messages = capture_broadcasts(@stream) do
      FieldTweetSource.transaction do
        assert_no_broadcasts(@stream) do
          @source.update!(state_reason: "Outer")
          FieldTweetSource.transaction(requires_new: true) { @source.update!(state_reason: "Inner") }
        end
      end
    end
    assert_equal Array.new(2) { { "action" => "refresh" } }, messages
  end

  test "tweet creation updates imported today even with no source and feature disabled" do
    @source.destroy!
    Setting.instance.update!(field_tweets_enabled: false)
    assert_difference -> { FieldTweets.imported_today(@account) }, 1 do
      assert_marker { create_tweet(101) }
    end
  end

  test "tweet edits discard restore tags and attribution do not change imported today" do
    tweet = create_tweet(101)
    assert_no_difference -> { FieldTweets.imported_today(@account) } do
      assert_no_broadcasts(@stream) do
        tweet.update!(text: "Edited", metrics: { likes: 10 }, field_tweet_source: @source)
        tweet.discard!
        tweet.undiscard!
        tweet.change_tags!(by: users(:user_1), add: [ "status-test" ])
        tweet.touch
      end
    end
  end

  test "a broken page still invalidates actual bulk backlog inserts with no source write" do
    prepare_broken_window
    assert_marker do
      FieldTweetSource.transaction do
        assert_no_broadcasts(@stream) { process_broken_page(101) }
      end
    end
    assert_equal 1, @source.backlog_items.count
    assert_nil @source.reload.last_success_at
    assert_no_broadcasts(@stream) { process_broken_page(101) }
    assert_no_broadcasts(@stream) { process_broken_page }
  end

  test "bulk insert conflict with an already inserted row stays quiet" do
    prepare_broken_window
    insert_all = FieldTweetBacklogItem.method(:insert_all)
    # A concurrent writer won between the known-id lookup and INSERT.
    conflict = ->(rows, **options) do
      insert_all.call(rows, **options)
      insert_all.call(rows, **options)
    end
    assert_no_broadcasts(@stream) do
      FieldTweetBacklogItem.stub(:insert_all, conflict) { process_broken_page(101) }
    end
    assert_equal 1, @source.backlog_items.count
  end

  test "bulk backlog insertion disappears on outer and savepoint rollback" do
    prepare_broken_window
    assert_no_broadcasts(@stream) do
      FieldTweetSource.transaction do
        process_broken_page(101)
        raise ActiveRecord::Rollback
      end
      FieldTweetSource.transaction do
        FieldTweetSource.transaction(requires_new: true) do
          process_broken_page(102)
          raise ActiveRecord::Rollback
        end
      end
    end
    assert_equal 0, @source.backlog_items.count
    assert_marker { process_broken_page(103) }
  end

  test "new tweet and backlog deletion coalesce into one transactional marker" do
    backlog(101)
    assert_marker { sync.send(:import_backlog!) }
    assert_equal 0, @source.backlog_items.count
    assert_equal 1, @account.field_tweets.count
    assert_no_broadcasts(@stream) { sync.send(:import_backlog!) }
  end

  test "draining a duplicate existing tweet still invalidates the backlog" do
    create_tweet(101)
    backlog(101)
    assert_no_difference -> { @account.field_tweets.count } do
      assert_marker { sync.send(:import_backlog!) }
    end
    assert_equal 0, @source.backlog_items.count
  end

  test "a concurrently removed backlog item does not produce a deletion marker" do
    create_tweet(101)
    stale = backlog(101)
    stale.delete
    oldest = Minitest::Mock.new
    oldest.expect(:limit, [ stale ], [ FieldTweets.import_allowance_left(@account) ])
    assert_no_broadcasts(@stream) do
      @source.backlog_items.stub(:oldest_first, oldest) { sync.send(:import_backlog!) }
    end
    oldest.verify
  end

  test "backlog drain and new tweet creation roll back together" do
    backlog(101)
    assert_no_broadcasts(@stream) do
      FieldTweet.transaction do
        sync.send(:import_backlog!)
        raise ActiveRecord::Rollback
      end
    end
    assert_equal 1, @source.backlog_items.count
    assert_equal 0, @account.field_tweets.count
    assert_marker { sync.send(:import_backlog!) }
  end

  test "savepoint backlog drain rollback stays quiet and preserves the queued tweet" do
    backlog(101)
    assert_no_broadcasts(@stream) do
      FieldTweet.transaction do
        FieldTweet.transaction(requires_new: true) do
          sync.send(:import_backlog!)
          raise ActiveRecord::Rollback
        end
      end
    end
    assert_equal 1, @source.backlog_items.count
    assert_equal 0, @account.field_tweets.count
    assert_marker { FieldTweet.transaction { assert_no_broadcasts(@stream) { sync.send(:import_backlog!) } } }
  end

  test "separate imports emit once per committed item and a caller transaction coalesces them" do
    3.times { |index| backlog(100 + index) }
    assert_equal 3, capture_broadcasts(@stream) { sync.send(:import_backlog!) }.size
    3.times { |index| backlog(200 + index) }
    assert_marker { FieldTweet.transaction { sync.send(:import_backlog!) } }
  end

  test "a three tweet worker run emits six content-free markers rather than one per save" do
    enable_field_tweets
    @account.update!(field_tweets_house_key: true)
    @source.update_columns(connected_at: @now - 15.minutes, checkpoint_at: @now - 15.minutes)
    client = FakeClient.new(page_of(3.times.map { |index| tweet_payload(100 + index, at: @now - 5.minutes) }))
    messages = capture_broadcasts(@stream) do
      with_house_key { assert_equal :done, run_sync(@source, client) }
    end
    # Open window, processed page, three item transactions, next-attempt time.
    assert_equal Array.new(6) { { "action" => "refresh" } }, messages
  end

  private

  def sync
    FieldTweets::Sync.new(@source, clock: -> { @now },
      client: ->(*) { raise "This test must not contact a provider" })
  end

  def create_tweet(id)
    @account.field_tweets.create!(FieldTweet.attributes_from(tweet_payload(id, at: @now), fetched_at: @now))
  end

  def backlog(id)
    attrs = FieldTweet.attributes_from(tweet_payload(id, at: @now), fetched_at: @now)
    @source.backlog_items.create!(provider_tweet_id: id.to_s, posted_at: @now, attrs: attrs)
  end

  def prepare_broken_window
    @source.update_columns(window_since: @now - 2.hours, window_until: @now - 1.minute, window_cursor: "same")
  end

  def process_broken_page(*ids)
    page = page_of(ids.map { |id| tweet_payload(id, at: @now - 5.minutes) }, cursor: "same")
    call = FieldTweetCall.new
    call.stub(:settle!, true) { assert_equal :broken, sync.send(:process_page!, page, call) }
  end

  def assert_marker(message = nil, &block)
    assert_no_broadcasts(@other_stream) do
      assert_equal [ { "action" => "refresh" } ], capture_broadcasts(@stream, &block), message
    end
  end

end
