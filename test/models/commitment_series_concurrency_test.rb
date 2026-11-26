require "test_helper"

# #1176 (Mira's P1): a cancel from an earlier occurrence racing the sweep's
# activation of the current one, on separate connections. Non-transactional
# so the row locks are really contended.
class CommitmentSeriesConcurrencyTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  setup do
    @account = users(:user_1).personal_account
    @agent = @account.agents.create!(name: "Series #{SecureRandom.hex(3)}", system_prompt: "Test", runtime: "external")
    @chat = @account.chats.new(title: "Series race", manual_responses: true)
    @chat.agents = [ @agent ]
    @chat.save!
    @first = Commitment.create!(agent: @agent, source_chat: @chat, text: "Until it is live", due_at: 1.hour.from_now,
                                recur_min_minutes: 30, recur_max_minutes: 30)
    @first.update_columns(status: "activated", activated_at: Time.current, wake_state: "delivered")
    @current = Commitment.create!(agent: @agent, source_chat: @chat, text: "Until it is live", due_at: 1.hour.from_now,
                                  recur_min_minutes: 30, recur_max_minutes: 30, series_root: @first,
                                  previous_commitment: @first, occurrence: 2)
    @current.update_columns(due_at: 1.minute.ago)
    @ready = Queue.new
    @release = Queue.new
  end

  teardown do
    @release.push(true)
    @threads&.each { |thread| thread.join(5) }
    ids = Commitment.where(agent_id: @agent.id).pluck(:id)
    Commitment.where(id: ids).update_all(series_root_id: nil, previous_commitment_id: nil, activation_message_id: nil,
                                         wake_interaction_id: nil, pending_wake_id: nil, pending_wake_source_id: nil)
    Commitment.where(id: ids).delete_all
    PendingWake.where(chat_id: @chat.id).delete_all if defined?(PendingWake)
    AgentRuntimeInteraction.where(chat_id: @chat.id).delete_all
    @chat.reload.destroy
    @agent.destroy
  end

  test "a cancel from an earlier occurrence waits for a racing activation and ends the series it made" do
    AgentRuntimeInteraction.stub(:live_activity_enabled?, true) do
      activation = in_thread do
        Commitment.transaction do
          result = Commitment.find(@current.id).activate!
          @ready.push(backend_pid)
          @release.pop
          result.status
        end
      end
      activate_pid = @ready.pop(timeout: 10) or flunk "activation never ran"
      successor = Commitment.find_by(previous_commitment_id: @current.id)
      assert_nil successor, "the successor is not visible before the activation commits"

      cancel_pids = Queue.new
      canceller = in_thread do
        cancel_pids.push(backend_pid)
        Commitment.find(@first.id).cancel!(by: @agent).status
      end
      cancel_pid = cancel_pids.pop(timeout: 10) or flunk "cancel never ran"
      # Wait until this canceller is blocked by this activation, not by any
      # unrelated backend on the test server (Mira's review of 90524f74).
      wait_until { blocking_pids(cancel_pid).include?(activate_pid) }
      @release.push(true)

      assert_equal :activated, activation.value
      assert_equal :series_ended, canceller.value
    end
    current = @current.reload
    assert_nil current.series_ended_reason, "the activation scheduled a successor"
    assert_equal 0, Commitment.scheduled.where(agent_id: @agent.id).count
    assert Commitment.find_by(previous_commitment_id: @current.id).cancelled?
  end

  private

  def in_thread(&block)
    thread = Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
    (@threads ||= []) << thread
    thread
  end

  def backend_pid
    ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()").to_i
  end

  def blocking_pids(pid)
    ActiveRecord::Base.uncached do
      ActiveRecord::Base.connection.select_values("SELECT unnest(pg_blocking_pids(#{Integer(pid)}))").map(&:to_i)
    end
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "timed out waiting" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

end
