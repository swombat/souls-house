require "test_helper"

# #94 B, step 8: concurrent writers in one chat. Revisions must become visible
# in revision order, or a client paging `changes` could advance past a revision
# that commits later and never see it. Non-transactional so the writers really
# contend on the chat row, each on its own connection.
class Message::RevisionedConcurrencyTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  setup do
    @user = users(:existing_user)
    @chat = accounts(:existing_user_account).chats.create!(model_id: "openrouter/auto", title: "Race")
  end

  teardown do
    @release&.push(true)
    @threads&.each { |thread| thread.join(5) }
    next unless @chat

    Message.with_discarded.where(chat_id: @chat.id).delete_all
    @chat.destroy!
  end

  test "a writer holding a revision blocks the next writer until it commits" do
    earlier = @chat.messages.create!(user: @user, role: "user", content: "earlier")
    @release = Queue.new
    held = Queue.new
    second = Queue.new

    in_thread do
      Message.transaction do
        held.push(@chat.messages.create!(user: @user, role: "user", content: "held").revision)
        @release.pop
      end
    end
    held_revision = held.pop

    in_thread { second.push(Message.find(earlier.id).tap { |m| m.update!(content: "edited") }.revision) }
    wait_for_blocked(1)

    assert second.empty?, "the second writer committed while the first held its revision"
    assert_empty visible_since(earlier.revision), "a reader saw a revision before the earlier one committed"

    @release.push(true)
    @threads.each { |thread| thread.join(5) }
    assert_equal held_revision + 1, second.pop
    assert_equal [ held_revision, held_revision + 1 ], visible_since(earlier.revision).map(&:revision)
  end

  test "a reader paging during concurrent writes misses nothing, and every revision is taken once" do
    writers = 3
    rounds = 5
    taken = Queue.new
    done = Queue.new

    writers.times do |w|
      in_thread do
        rounds.times do |r|
          message = @chat.messages.create!(user: @user, role: "user", content: "w#{w} r#{r}")
          taken.push(message.revision)
          message.update!(content: "w#{w} r#{r} edited")
          taken.push(message.revision)
        end
        done.push(w)
      end
    end

    seen = {}
    since = 0
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    loop do
      @threads.each { |t| t.join if t.status.nil? } # re-raises a writer's exception
      flunk "writers didn't finish" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      finished = done.size == writers
      page = visible_since(since, limit: 3)
      page.each { |m| seen[m.id] = m.revision }
      since = page.last.revision if page.any?
      break if finished && page.empty?
    end
    @threads.each(&:join)

    total = writers * rounds * 2
    assert_equal (1..total).to_a, Array.new(taken.size) { taken.pop }.sort
    assert_equal total, @chat.reload.message_revision
    assert_equal Message.where(chat_id: @chat.id).pluck(:id, :revision).to_h, seen
  end

  private

  # What a `changes` page reads, on this thread's own connection.
  def visible_since(since, limit: 100)
    ActiveRecord::Base.uncached do
      Message.with_discarded.where(chat_id: @chat.id).where("revision > ?", since).reorder(:revision).limit(limit).to_a
    end
  end

  def in_thread(&block)
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(&block)
    end
    thread.report_on_exception = false
    (@threads ||= []) << thread
    thread
  end

  def wait_for_blocked(count, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      waiting = ActiveRecord::Base.uncached do
        ActiveRecord::Base.connection.select_value(
          "SELECT count(*) FROM pg_locks WHERE NOT granted AND locktype IN ('transactionid', 'tuple')"
        ).to_i
      end
      break if waiting >= count
      flunk "expected #{count} blocked transaction(s), saw #{waiting}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

end
