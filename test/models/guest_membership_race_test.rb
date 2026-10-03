require "test_helper"

# Admission and departure on separate connections, interleaved on purpose.
# A seat created without a guest membership grants reads and wakes through
# Agent#chats, so neither order may leave one behind.
class GuestMembershipRaceTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  setup do
    @nexus = accounts(:team_account)
    @lume = agents(:research_assistant)
    @membership = @nexus.guest_memberships.create!(agent: @lume, added_by: users(:user_1))
    @room = @nexus.chats.create!(model_id: "openrouter/auto", manual_responses: true, title: "Race", agents: [ agents(:other_account_agent) ])
  end

  teardown do
    ChatAgent.where(chat_id: @room.id).delete_all
    Message.where(chat_id: @room.id).delete_all
    Chat.where(id: @room.id).delete_all
    GuestMembership.where(id: @membership.id).delete_all
  end

  test "a departure waits for an admission in flight, then closes the late seat" do
    seated = Queue.new
    release = Queue.new
    admission = Thread.new do
      on_own_connection do
        ChatAgent.transaction do
          ChatAgent.create!(chat: Chat.find(@room.id), agent: Agent.find(@lume.id))
          seated << true
          release.pop
        end
      end
    end
    seated.pop

    departure = Thread.new { on_own_connection { GuestMembership.find(@membership.id).destroy! } }
    begin
      wait_for_a_lock_wait
    ensure
      release << true
      [ admission, departure ].each { |thread| thread.join(10) || flunk("a thread never finished") }
    end

    assert_not ChatAgent.exists?(chat_id: @room.id, agent_id: @lume.id)
    assert_not GuestMembership.exists?(@membership.id)
  end

  test "an admission that starts after a departure holds the membership is refused" do
    locked = Queue.new
    release = Queue.new
    departure = Thread.new do
      on_own_connection do
        GuestMembership.transaction do
          membership = GuestMembership.find(@membership.id)
          membership.lock!
          locked << true
          release.pop
          membership.destroy!
        end
      end
    end
    locked.pop

    admission = Thread.new do
      on_own_connection do
        ChatAgent.create!(chat: Chat.find(@room.id), agent: Agent.find(@lume.id))
        :seated
      rescue ActiveRecord::RecordInvalid
        :refused
      end
    end
    begin
      wait_for_a_lock_wait
    ensure
      release << true
      [ departure, admission ].each { |thread| thread.join(10) || flunk("a thread never finished") }
    end

    assert_equal :refused, admission.value
    assert_not ChatAgent.exists?(chat_id: @room.id, agent_id: @lume.id)
  end

  private

  def on_own_connection(&)
    ActiveRecord::Base.connection_pool.with_connection(&)
  end

  # Proves the second actor is actually blocked on the first, rather than
  # trusting a sleep to order them. Uncached: the query cache would otherwise
  # replay the first (empty) answer forever.
  def wait_for_a_lock_wait
    deadline = 5.seconds.from_now
    until ActiveRecord::Base.uncached { ActiveRecord::Base.connection.select_value(
      "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
    ) }.to_i.positive?
      flunk "the second actor never waited on the first: #{ActiveRecord::Base.connection.select_rows("SELECT datname, state, wait_event_type, left(query, 80) FROM pg_stat_activity WHERE datname LIKE 'souls_house%'").inspect}" if Time.current > deadline
      sleep 0.01
    end
  end

end
