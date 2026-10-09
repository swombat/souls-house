require "test_helper"

# A held wake's release and claim against a withdrawal in flight (Mira's
# second review of #252), on two real connections. Non-transactional, so the
# row locks are actually contended: the withdrawal is paused inside its own
# transaction, after its write, until Postgres reports the release or claim
# blocked on it. The decision must then see the committed withdrawal.
# Without the locks the decision doesn't wait, reads the old row, and lets
# the run start.
class PendingWakeClaimRaceTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  setup do
    @user = users(:existing_user)
    @account = accounts(:existing_user_account)
    @resident = @account.agents.create!(name: "Busy", system_prompt: "Test", runtime: "external")
    @sibling = @account.agents.create!(name: "Reviewer", system_prompt: "Test", runtime: "external")
    @chat = @account.chats.new(model_id: "openrouter/auto", title: "Race", manual_responses: true)
    @chat.agent_ids = [ @resident.id, @sibling.id ]
    @chat.save!
    @message = @chat.messages.create!(role: "user", user: @user, content: "Over to you")
  end

  teardown do
    @release&.push(true)
    @threads&.each { |thread| thread.join(5) }
    next unless @chat

    PendingWake.where(chat: @chat).delete_all
    AgentRuntimeInteraction.where(chat: @chat).update_all(message_dispatch_id: nil)
    MessageDispatch.where(chat: @chat).delete_all
    AgentRuntimeInteraction.where(chat: @chat).delete_all
    Message.where(chat: @chat).delete_all
    @chat.destroy!
    [ @resident, @sibling ].each(&:destroy!)
  end

  test "a discard in flight when the released run claims is waited for, and stops the run" do
    run = released_run
    withdrawing { Message.find(@message.id).discard! }

    claimed = decide { AgentRuntimeInteraction.find(run.id).claim_dispatch! }

    assert_equal false, claimed
    assert_equal "cancelled", run.reload.execution_state
    assert_equal "claim_refused:sources_withdrawn", run.released_pending_wake.drop_reason
  end

  test "a pause in flight when the released run claims is waited for, and stops the run" do
    run = released_run
    withdrawing { Agent.find(@resident.id).update!(paused: true) }

    claimed = decide { AgentRuntimeInteraction.find(run.id).claim_dispatch! }

    assert_equal false, claimed
    assert_equal "claim_refused:paused", run.released_pending_wake.reload.drop_reason
  end

  test "an edit in flight when the wake is released is waited for, and withdraws its message" do
    wake = PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "a message", message: @message)
    withdrawing { Message.find(@message.id).update_as_author(content: "Never mind") }

    decide do
      AgentRuntimeInteraction.stub(:live_activity_enabled?, true) do
        PendingWake.release!(chat: Chat.find(@chat.id), agent: Agent.find(@resident.id))
      end
    end

    assert_equal "sources_withdrawn", wake.reload.drop_reason
    assert_equal 0, AgentRuntimeInteraction.where(chat: @chat).count
  end

  private

  # A wake released into a reserved, unclaimed run.
  def released_run
    PendingWake.queue!(chat: @chat, agent: @resident, requested_by: "a message", message: @message)
    AgentRuntimeInteraction.stub(:live_activity_enabled?, true) do
      PendingWake.release!(chat: @chat, agent: @resident)
    end
    PendingWake.find_by!(chat: @chat, agent: @resident).released_interaction.tap { |run| assert run }
  end

  # Start the withdrawal on its own connection and hold its transaction open
  # after the write, until the decision has blocked on it.
  def withdrawing(&write)
    @release = Queue.new
    written = Queue.new
    in_thread do
      ActiveRecord::Base.transaction do
        write.call
        written << true
        @release.pop
      end
    rescue StandardError => error
      written << error
    end
    result = written.pop(timeout: 10)
    raise result if result.is_a?(Exception)

    assert_equal true, result, "the withdrawal never wrote"
  end

  # Run the decision on another connection; it must block on the withdrawal.
  # Then let the withdrawal commit and return the decision's result.
  def decide(&decision)
    results = Queue.new
    in_thread do
      results << decision.call
    rescue StandardError => error
      results << error
    end
    wait_for_blocked(1)
    @release.push(true)
    result = results.pop(timeout: 10)
    raise result if result.is_a?(Exception)

    result
  end

  def in_thread(&block)
    thread = Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
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
      flunk "expected the decision to block on the withdrawal; saw #{waiting} blocked" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

end
