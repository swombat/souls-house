require "test_helper"

# Real locks on two connections: a resident restarting (its row held for the
# whole docker recreate) must not make a turn for it wait while that turn's
# transaction holds the house-wide gate. Mira's catch on #734.
class ResidentRowLockContentionTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  class LockProbe < ApplicationRecord

    self.table_name = "agents"

  end

  setup do
    LockProbe.establish_connection(ActiveRecord::Base.connection_db_config.configuration_hash)
    @agent = agents(:research_assistant)
    @interaction = AgentRuntimeInteraction.create!(agent: @agent, trigger_kind: "wake",
      session_id: "row-lock-session", started_at: Time.current, endpoint_url: "https://runtime.example.test")
  end

  teardown do
    ResidentTurn.where(agent_runtime_interaction: @interaction).delete_all
    @interaction.delete
  end

  def enqueue_while_row_held(lock_clause)
    locked, release = Queue.new, Queue.new
    holder = Thread.new do
      LockProbe.connection_pool.with_connection do
        LockProbe.find(@agent.id).with_lock(lock_clause) do
          locked << true
          release.pop
        end
      end
    end
    locked.pop
    ResidentTurn.transaction do
      ResidentTurn.connection.execute("SET LOCAL lock_timeout = '2s'")
      ResidentTurn.enqueue!(@interaction, {session_id: "row-lock-session"})
    end
  ensure
    release << true
    holder&.join
  end

  test "a turn for a restarting resident enqueues without waiting on its row" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    turn = enqueue_while_row_held(Agents::Sandbox::ROW_LOCK)
    assert_equal "queued", turn.reload.state
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.5
  end

  test "control: FOR UPDATE on the row would block the insert under the gate" do
    assert_raises(ActiveRecord::LockWaitTimeout) { enqueue_while_row_held("FOR UPDATE") }
  end

  # The whole real recreate! chain (recreate! -> spawn!, each with its own
  # with_lock), with only docker stubbed: no nested lock may upgrade the row
  # back to FOR UPDATE while the container work is in flight.
  test "a turn enqueues while Sandbox#recreate! is mid-spawn" do
    locked, release = Queue.new, Queue.new
    holder = Thread.new do
      LockProbe.connection_pool.with_connection do
        # The sandbox uses Agent's connection; give this thread its own.
        ActiveRecord::Base.connection_pool.with_connection do
          agent = Agent.find(@agent.id)
          sandbox = Agents::Sandbox.new(agent)
          sandbox.define_singleton_method(:ensure_awake!) { nil }
          sandbox.define_singleton_method(:ensure_memory_not_suspended!) { nil }
          sandbox.define_singleton_method(:container_exists?) { false }
          sandbox.define_singleton_method(:remove!) { |**| nil }
          sandbox.define_singleton_method(:spawn_without_portability_gate!) do
            locked << true
            release.pop
          end
          Agents::RuntimeLocation.stub(:require_local!, nil) do
            Agent.transaction { sandbox.recreate! }
          end
        end
      end
    rescue StandardError => e
      locked << e
    end
    signal = locked.pop
    raise signal if signal.is_a?(Exception)
    turn = ResidentTurn.transaction do
      ResidentTurn.connection.execute("SET LOCAL lock_timeout = '2s'")
      ResidentTurn.enqueue!(@interaction, {session_id: "row-lock-session"})
    end
    assert_equal "queued", turn.reload.state
  ensure
    release << true
    holder&.join
  end

end
