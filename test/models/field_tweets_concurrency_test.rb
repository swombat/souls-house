require "test_helper"
require "support/field_tweet_helpers"

# Two workers reserving at once must not both take the last of the house's
# monthly allowance (FieldTweets.reserve! holds one lock over the ledger).
class FieldTweetsConcurrencyTest < ActiveSupport::TestCase

  include FieldTweetHelpers

  self.use_transactional_tests = false

  setup do
    @setting_was = Setting.instance.attributes.select { |name, _| name.start_with?("field_tweets_") }
    @account = Account.create!(name: "Tweet race #{SecureRandom.hex(4)}", account_type: "team")
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

end
