require "test_helper"

# Two health jobs can overlap: the probes are sequential network calls and can
# outlast the five-minute schedule. Non-transactional so the two observers run
# on separate connections: the first is paused after it has read the latch,
# and the second must wait for it rather than read the same empty (or the
# same open) latch and say the thing a second time.
class ResidentUnreachableNoticeConcurrencyTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  setup do
    @last_audit_id = AuditLog.maximum(:id).to_i
    @last_chat_id = Chat.maximum(:id).to_i
    @account = accounts(:existing_user_account)
    @agent = @account.agents.create!(name: "Racer", system_prompt: "Test", runtime: "external")
    @agent.update_columns(health_state: "unhealthy", consecutive_health_failures: 3,
      health_failing_since: 20.minutes.ago, last_health_check_at: 5.minutes.ago)
  end

  teardown do
    @release&.push(true)
    @threads&.each { |thread| thread.join(5) }
    Chat.where("id > ?", @last_chat_id).find_each do |chat|
      chat.messages.delete_all
      chat.destroy!
    end
    AuditLog.where("id > ?", @last_audit_id).delete_all
    @agent&.destroy!
  end

  def outages = AuditLog.where(action: ResidentUnreachableNotice::UNREACHABLE, auditable: @agent)
  def recoveries = AuditLog.where(action: ResidentUnreachableNotice::REACHABLE, auditable: @agent)

  test "two overlapping observations of a third failure open one outage" do
    race_two_observers

    assert_equal 1, outages.count
    assert_equal 1, Chat.where("id > ?", @last_chat_id).count
  end

  test "two overlapping observations of a recovery close the outage once" do
    ResidentUnreachableNotice.observe!(Agent.find(@agent.id))
    assert_equal 1, outages.count
    @agent.update_columns(health_state: "healthy", consecutive_health_failures: 0, health_failing_since: nil)

    race_two_observers

    assert_equal 1, recoveries.count
    chat = Chat.find(outages.sole.data["chat_id"])
    assert_equal 1, chat.messages.where(role: "system").where("content LIKE ?", "%answering again%").count
  end

  private

  # The first observer reads the latch and stops there until released; the
  # second must then be blocked by Postgres, not racing past it.
  def race_two_observers
    @release = Queue.new
    paused = Queue.new
    original = ResidentUnreachableNotice.method(:open_outage)
    first = true
    lock = Mutex.new
    pausing_read = lambda do |agent|
      result = original.call(agent)
      if lock.synchronize { first.tap { first = false } }
        paused << true
        raise "first observer was never released" unless @release.pop(timeout: 10)
      end
      result
    end

    ResidentUnreachableNotice.stub(:open_outage, pausing_read) do
      in_thread { ResidentUnreachableNotice.new(Agent.find(@agent.id)).observe! }
      assert_equal true, paused.pop(timeout: 10), "first observer never read the latch"
      in_thread { ResidentUnreachableNotice.new(Agent.find(@agent.id)).observe! }
      wait_for_blocked(1)
      @release.push(true)
      @threads.each { |thread| assert thread.join(10), "an observer did not finish" }
    end
  end

  def in_thread(&block)
    thread = Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection(&block)
    end
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
      flunk "expected #{count} blocked observer(s), saw #{waiting}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

end
