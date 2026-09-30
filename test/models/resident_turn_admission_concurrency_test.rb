require "test_helper"

class ResidentTurnAdmissionConcurrencyTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  test "simultaneous dispatchers cannot claim the last slot twice" do
    old_limit = ResidentTurn.capacity
    Setting.instance.update!(resident_turn_limit: 1)
    interactions = 3.times.map do
      interaction = AgentRuntimeInteraction.create!(
        agent: agents(:research_assistant), trigger_kind: "wake",
        session_id: SecureRandom.uuid, started_at: Time.current
      )
      ResidentTurn.enqueue!(interaction, { session_id: interaction.session_id, request: "synthetic" })
      interaction
    end
    ready, start = Queue.new, Queue.new
    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          ResidentTurn.admit!
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    admitted = workers.flat_map(&:value)
    assert_equal 1, admitted.length
    assert_equal 1, ResidentTurn.occupying_capacity.count
  ensure
    workers&.each(&:join)
    interactions&.each(&:destroy!)
    Setting.instance.update!(resident_turn_limit: old_limit) if old_limit
  end

end
