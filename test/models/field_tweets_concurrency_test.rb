require "test_helper"
require "support/field_tweet_helpers"
require "timeout"

# Two workers reserving at once must not both take the last of the house's
# monthly allowance (FieldTweets.reserve! holds one lock over the ledger).
class FieldTweetsConcurrencyTest < ActiveSupport::TestCase

  include FieldTweetHelpers

  self.use_transactional_tests = false

  setup do
    @setting_was = Setting.instance.attributes.select { |name, _| name.start_with?("field_tweets_") }
    @account = Account.create!(name: "Tweet race #{SecureRandom.hex(4)}", account_type: "team", field_tweets_house_key: true)
    enable_field_tweets(site: "0.004", account: "1")
    @source = @account.create_field_tweet_source!(handle: "racer")
  end

  teardown do
    FieldTweetCall.where(account: @account).delete_all
    @account.destroy!
    Setting.instance.update_columns(@setting_was)
  end

  test "only one of two simultaneous reservations fits the ceiling" do
    ready, start = Queue.new, Queue.new
    # Stubbed once, outside the threads: a stub is a method swap the threads share.
    values = with_house_key do
      threads = 2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            start.pop
            FieldTweets.reserve!(FieldTweetSource.find(@source.id)).class.name
          rescue FieldTweets::LimitReached
            "LimitReached"
          end
        end
      end
      2.times { ready.pop }
      2.times { start << true }
      threads.map(&:value)
    end

    assert_equal [ "FieldTweetCall", "LimitReached" ], values.sort
    assert_equal 1, FieldTweetCall.where(account: @account).count
  end

  test "removal holding the source row prevents a waiting reservation" do
    worker = nil
    with_house_key do
      @source.with_lock do
        @source.remove!
        worker, pid = on_connection do
          FieldTweets.reserve!(FieldTweetSource.find(@source.id))
        rescue FieldTweets::InactiveSource
          :inactive
        end
        wait_for_database_lock(pid)
      end
      assert_equal :inactive, worker.value
    end
    assert_empty FieldTweetCall.where(account: @account)
  ensure
    worker&.join
  end

  test "a reservation admitted before removal remains charged and cannot admit another" do
    worker = nil
    with_house_key do
      FieldTweetCall.transaction do
        call = FieldTweets.reserve!(@source)
        assert_equal "reserved", call.status
        worker, pid = on_connection { FieldTweetSource.find(@source.id).remove! }
        wait_for_database_lock(pid)
        assert_not @source.reload.removed?
      end
      worker.value
      assert @source.reload.removed?
      assert_equal "reserved", FieldTweetCall.where(account: @account).sole.status
      assert_raises(FieldTweets::InactiveSource) { FieldTweets.reserve!(@source) }
    end
  ensure
    worker&.join
  end

  test "removal freezes an import already waiting for the source row" do
    add_backlog
    sync = FieldTweets::Sync.new(FieldTweetSource.find(@source.id))
    assert sync.send(:claim!)
    worker = nil
    @source.with_lock do
      worker, pid = on_connection { sync.send(:import_backlog!) }
      wait_for_database_lock(pid)
      @source.remove!
    end
    assert_equal 0, worker.value
    assert_equal 1, @source.backlog_items.count
    assert_equal 0, FieldTweets.imported_today(@account)
  ensure
    worker&.join
    sync&.send(:release!)
  end

  test "an import holding the source row commits before waiting removal" do
    add_backlog
    sync = FieldTweets::Sync.new(@source)
    assert sync.send(:claim!)
    worker = nil
    @source.with_lock do
      worker, pid = on_connection { FieldTweetSource.find(@source.id).remove! }
      wait_for_database_lock(pid)
      assert_equal 1, sync.send(:import_backlog!)
    end
    worker.value
    assert @source.reload.removed?
    assert_empty @source.backlog_items
    assert_equal 1, FieldTweets.imported_today(@account)
    assert_equal @source.id, @account.field_tweets.sole.field_tweet_source_id
  ensure
    worker&.join
    sync&.send(:release!)
  end

  test "provider HTTP holds neither source row nor global ledger lock" do
    @source.update!(connected_at: Time.current - 1.hour, checkpoint_at: Time.current - 1.hour)
    entered, finish = Queue.new, Queue.new
    page = page_of([ tweet_payload(1, at: Time.current - 5.minutes) ])
    client = Object.new
    client.define_singleton_method(:search) do |*, **|
      entered << true
      finish.pop
      page
    end
    worker = nil
    with_house_key do
      worker, = on_connection do
        FieldTweets::Sync.new(FieldTweetSource.find(@source.id), client: ->(_) { client }).call
      end
      Timeout.timeout(10) { entered.pop }
      # These operations finish before allowing the fake HTTP response through.
      Timeout.timeout(10) do
        @source.remove!
        assert_raises(FieldTweets::InactiveSource) { FieldTweets.reserve!(@source) }
      end
      finish << true
      assert_equal :inactive, worker.value
    end
    assert_equal "settled", FieldTweetCall.where(account: @account).sole.status
    assert_equal 1, @source.backlog_items.count
    assert_equal 0, FieldTweets.imported_today(@account)
    assert_nil @source.reload.window_cursor
    assert_not @source.window_open?
  ensure
    finish << true if finish
    worker&.join
  end

  private

  def add_backlog
    attrs = FieldTweet.attributes_from(tweet_payload(1, at: Time.current), fetched_at: Time.current)
    @source.backlog_items.create!(provider_tweet_id: "1", posted_at: Time.current, attrs: attrs)
  end

  def on_connection(&operation)
    ready = Queue.new
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        ready << connection.select_value("SELECT pg_backend_pid()")
        operation.call
      end
    end
    [ worker, Timeout.timeout(10) { ready.pop } ]
  end

  # Barrier on actual PostgreSQL lock contention, not timing/sleep assumptions.
  def wait_for_database_lock(pid)
    ActiveRecord::Base.uncached do
      Timeout.timeout(10) do
        until ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{Integer(pid)})) > 0")
          Thread.pass
        end
      end
    end
  end

end
