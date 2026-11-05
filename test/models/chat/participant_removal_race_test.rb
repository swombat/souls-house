require "test_helper"

class Chat::ParticipantRemovalRaceTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  setup do
    @user = users(:existing_user)
    @agent = @user.personal_account.agents.create!(name: "Removal race", runtime: "external", system_prompt: "Test")
    @chat = @agent.account.chats.create!(manual_responses: true, agents: [ @agent ])
    @threads = []
    @release = Queue.new
  end

  teardown do
    @release.push(true)
    @threads.each { |thread| thread.join(10) }
    AgentRuntimeInteraction.where(chat: @chat).delete_all
    @chat.destroy!
    @agent.destroy!
  end

  test "removal winning the room lock prevents an invocation waiting on it" do
    hold_transaction { Chat.find(@chat.id).remove_participant!(@agent, by: @user) }
    result = contend { AgentRuntimeInteraction.reserve!(chat: Chat.find(@chat.id), agent: @agent) }
    assert_kind_of ArgumentError, result
    assert_not @chat.chat_agents.exists?
    assert_not AgentRuntimeInteraction.exists?(chat: @chat)
  end

  test "invocation winning the room lock makes removal refuse without cancelling" do
    hold_transaction { AgentRuntimeInteraction.reserve!(chat: Chat.find(@chat.id), agent: @agent) }
    result = contend { Chat.find(@chat.id).remove_participant!(@agent, by: @user) }
    assert_kind_of Chat::AlreadyResponding, result
    assert @chat.chat_agents.exists?(agent: @agent)
    assert_nil AgentRuntimeInteraction.find_by!(chat: @chat).finished_at
  end

  private

  def hold_transaction
    ready = Queue.new
    in_thread do
      ActiveRecord::Base.transaction do
        yield
        ready << true
        @release.pop
      end
    rescue StandardError => error
      ready << error
    end
    assert_equal true, ready.pop(timeout: 10)
  end

  def contend
    result = Queue.new
    pid = Queue.new
    in_thread do
      pid << ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
      result << yield
    rescue StandardError => error
      result << error
    end
    backend_pid = Integer(pid.pop(timeout: 10))
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    loop do
      blocked = ActiveRecord::Base.uncached do
        ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{backend_pid}))").to_i.positive?
      end
      break if blocked
      flunk "operation did not wait for the chat lock" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
    @release << true
    result.pop(timeout: 10)
  end

  def in_thread(&block)
    @threads << Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
  end

end
