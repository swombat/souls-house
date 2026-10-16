require "test_helper"
require "timeout"

class FieldSongOfferConcurrencyTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Song offer race #{SecureRandom.hex(4)}", account_type: :team)
    @user = users(:user_1)
  end

  teardown do
    @account.field_songs.find_each(&:destroy!)
    @account.destroy!
  end

  test "concurrent equivalent saves wait on the account row and return the same untouched song" do
    checked, release, started = Queue.new, Queue.new, Queue.new
    first_offer = FieldSong::Offer.new(account: Account.find(@account.id), url: "https://youtu.be/y8AWFf7EAc4")
    # Pause after the first absence check while its account lock is held.
    first_offer.define_singleton_method(:existing_song) do
      super().tap { checked << true; release.pop }
    end

    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        first_offer.save!(title: "First title", artist: "First artist", by: @user)
      end
    end
    second = nil
    begin
      Timeout.timeout(10) { checked.pop }
      second = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          offer = FieldSong::Offer.new(account: Account.find(@account.id),
            url: "https://www.youtube.com/watch?v=y8AWFf7EAc4&feature=shared")
          started << connection.select_value("SELECT pg_backend_pid()").to_i
          offer.save!(title: "Second title", artist: "Second artist", by: @user)
        end
      end
      # Not Timeout: on a stall, say where the second thread is stuck. It has
      # stalled here on CI (2026-10-16, #399) without raising, then finished
      # once the first save was released, so it waits on something the first
      # holds, and the backtrace and pool state should name it.
      backend_pid = started.pop(timeout: 10) or
        flunk "the second thread never reached its first query (status #{second.status.inspect}, " \
              "pool #{ActiveRecord::Base.connection_pool.stat.inspect}):\n#{Array(second.backtrace).first(25).join("\n")}"
      # Uncached: every test runs inside the executor, which turns the query
      # cache on for this thread, so a cached poll would replay its first
      # answer for the whole wait. When the first poll ran before the second
      # thread reached the lock, that answer was "not blocked" forever (master
      # reds on 2026-10-15 and 16).
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      blocked = loop do
        waiting = ActiveRecord::Base.uncached do
          ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{backend_pid}))").to_i.positive?
        end
        break true if waiting
        break false unless second.alive?
        flunk "the second save was still running after 10 s without waiting on any lock" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.02
      end
      assert blocked, "the second save must actually wait on the first transaction's account row lock"
    ensure
      release << true
      Timeout.timeout(10) { first.join; second&.join }
    end

    assert_equal first.value.id, second.value.id
    assert first.value.previously_new_record?
    assert_not second.value.previously_new_record?
    assert_equal 1, @account.field_songs.kept.count
    song = @account.field_songs.kept.first
    assert_equal [ "First title", "First artist" ], [ song.title, song.artist ]
    assert_equal @user, song.added_by
    assert_nil song.lyrics
    assert_nil song.note
    assert_nil song.shared_for
  end

end
