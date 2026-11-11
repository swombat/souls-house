require "test_helper"
require "timeout"

class ChatWorkStatusAuthorityRaceTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  setup do
    @host = accounts(:team_account)
    @agent = agents(:research_assistant)
    @membership = @host.guest_memberships.create!(agent: @agent, added_by: users(:user_1))
    @chat = @host.chats.create!(model_id: "openrouter/auto", manual_responses: true, agents: [ @agent ])
  end

  teardown do
    ChatAgent.where(chat_id: @chat.id).delete_all
    Message.where(chat_id: @chat.id).delete_all
    Chat.where(id: @chat.id).delete_all
    GuestMembership.where(id: @membership.id).delete_all
  end

  test "a departure holding the guest membership wins over a previously fetched chat" do
    stale_chat = @chat
    locked, release = Queue.new, Queue.new
    departure = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        GuestMembership.transaction do
          membership = GuestMembership.find(@membership.id)
          membership.lock!
          locked << true
          release.pop
          membership.destroy!
        end
      end
    end
    Timeout.timeout(10) { locked.pop }
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        stale_chat.with_work_status_authority!(agent: @agent) do
          stale_chat.change_work_status!(state: "completed", reason: nil, expected_revision: 0)
        end
        :written
      rescue ActiveRecord::RecordNotFound
        :refused
      end
    end
    begin
      wait_for_lock
    ensure
      release << true
      [ departure, writer ].each { |thread| thread.join(10) || flunk("thread did not finish") }
    end
    assert_equal :refused, writer.value
    assert_nil @chat.reload.work_status
  end

  test "a status write holds the guest stay until commit then departure closes the seat" do
    locked, release = Queue.new, Queue.new
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        chat = Chat.find(@chat.id)
        chat.with_work_status_authority!(agent: @agent) do
          locked << true
          release.pop
          chat.change_work_status!(state: "working", reason: nil, expected_revision: 0)
        end
      end
    end
    Timeout.timeout(10) { locked.pop }
    departure = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { GuestMembership.find(@membership.id).destroy! }
    end
    begin
      wait_for_lock
    ensure
      release << true
      [ writer, departure ].each { |thread| thread.join(10) || flunk("thread did not finish") }
    end
    assert_equal "working", @chat.reload.work_status
    assert_not @chat.chat_agents.exists?(agent_id: @agent.id)
    assert_not GuestMembership.exists?(@membership.id)
  end

  private

  def wait_for_lock
    Timeout.timeout(5) do
      until ActiveRecord::Base.uncached {
        ActiveRecord::Base.connection.select_value(
          "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
        ).to_i.positive?
      }
        sleep 0.01
      end
    end
  end

end
