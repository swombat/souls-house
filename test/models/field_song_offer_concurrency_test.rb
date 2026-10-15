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
      backend_pid = Timeout.timeout(10) { started.pop }
      blocked = Timeout.timeout(10) do
        loop do
          waiting = ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{backend_pid}))").to_i.positive?
          break true if waiting
          break false unless second.alive?
          Thread.pass
        end
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
