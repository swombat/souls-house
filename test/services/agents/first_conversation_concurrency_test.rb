require "test_helper"

# Real interleavings on separate connections (Mira's review of #587): a
# person's message and the greeting's claim or cleanup, each paused at the
# contended point until Postgres reports the other side blocked on it.
# Non-transactional, so the row locks are actually contended.
class Agents::FirstConversationConcurrencyTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  setup do
    @account = accounts(:existing_user_account)
    @person = @account.owner
    @agent = @account.agents.create!(
      name: "Firstborn #{SecureRandom.hex(3)}", system_prompt: "Test", runtime: "external", health_state: "healthy",
      birth_committed_at: Time.current, uuid: SecureRandom.uuid_v7, created_by_user: @person,
      orientation_completed_at: Time.current
    )
    assert_equal :opened, Agents::FirstConversation.open!(@agent)
    ExternalAgentResponseRequest.stub(:new, ->(**) { raise "stop before dispatch" }) do
      assert_raises(RuntimeError) { Agents::FirstConversation.wake!(@agent) }
    end
    @agent.reload
    @interaction = @agent.first_conversation_interaction
    @house_chat = @agent.first_conversation_chat
    @threads = []
  end

  teardown do
    @release&.push(true)
    @threads.each { |thread| thread.join(5) }
    chat_ids = @agent.chats.ids + [ @house_chat&.id ].compact
    @agent.update_columns(first_conversation_interaction_id: nil, first_conversation_chat_id: nil)
    Message.where(chat_id: chat_ids).delete_all
    AgentRuntimeInteraction.where(agent_id: @agent.id).delete_all
    MessageDispatch.where(chat_id: chat_ids).delete_all
    Chat.where(id: chat_ids).destroy_all
    @agent.destroy!
  end

  test "a message being posted while the greeting is claimed lands first and stops the greeting" do
    @release = Queue.new
    posted = Queue.new
    person = in_thread do
      Message.transaction do
        Chat.find(@house_chat.id).messages.create!(role: "user", user: @person, content: "hi", suppress_automatic_dispatch: true)
        posted << true
        @release.pop
      end
    end
    assert_equal true, posted.pop(timeout: 10), "the person's message never reached its insert"

    claim = in_thread { AgentRuntimeInteraction.find(@interaction.id).claim_dispatch! }
    wait_for_blocked(1)
    @release.push(true)

    assert_equal :ok, person.value.first, person.value.last.inspect
    outcome, claimed = claim.value
    assert_equal :ok, outcome, claimed.inspect
    assert_equal false, claimed, "the greeting must not be claimed after a person has written"
    assert_equal "skipped", @agent.reload.first_conversation_greeting
    assert_equal "cancelled", @interaction.reload.execution_state
    assert_equal 1, @house_chat.messages.count
  end

  test "a message posted after the gate's checks waits for the claim, so it can't slip between check and claim" do
    @release = Queue.new
    checked = Queue.new
    original = AgentRuntimeInteraction.instance_method(:claim_dispatch_unchecked!)
    release = @release
    interaction = AgentRuntimeInteraction.find(@interaction.id)
    interaction.define_singleton_method(:claim_dispatch_unchecked!) do
      checked << true
      release.pop
      original.bind_call(self)
    end
    claim = in_thread { interaction.claim_dispatch! }
    assert_equal true, checked.pop(timeout: 10), "the claim never passed its checks"

    person = in_thread do
      Chat.find(@house_chat.id).messages.create!(role: "user", user: @person, content: "hi", suppress_automatic_dispatch: true)
    end
    wait_for_blocked(1)
    @release.push(true)

    assert_equal [ :ok, true ], claim.value
    assert_equal :ok, person.value.first, person.value.last.inspect
    assert_operator @interaction.reload.dispatch_claimed_at, :<=, @house_chat.messages.last.created_at
  end

  test "removing the empty house conversation never deletes a message posted at that moment" do
    theirs = @account.chats.create!(title: "Mine", manual_responses: true, agent_ids: [ @agent.id ])
    theirs.messages.create!(role: "user", user: @person, content: "hello", suppress_automatic_dispatch: true)

    @release = Queue.new
    locked = Queue.new
    cleanup = in_thread do
      chat = Chat.find(@house_chat.id)
      agent = Agent.find(@agent.id)
      chat.with_lock do
        agent.with_lock do
          locked << true
          @release.pop
          Agents::FirstConversation.new(agent).send(:person_first, chat)
        end
      end
    end
    assert_equal true, locked.pop(timeout: 10)

    late = in_thread do
      Chat.find(@house_chat.id).messages.create!(role: "user", user: @person, content: "wait", suppress_automatic_dispatch: true)
    end
    wait_for_blocked(1)
    @release.push(true)

    assert_equal [ :ok, :skipped ], cleanup.value
    outcome, error = late.value
    assert_equal :error, outcome, "the late message must fail visibly, not be deleted with the chat"
    # It waits on the chat row (its revision bump and foreign key both need
    # it) and then fails on the missing chat; nothing is silently deleted.
    assert_kind_of ActiveRecord::StatementInvalid, error
    assert_equal 0, Message.where(chat_id: @house_chat.id).count
    refute Chat.exists?(@house_chat.id)
    assert_equal theirs, @agent.reload.first_conversation_chat
    @house_chat = nil
  end

  private

  def in_thread(&block)
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        [ :ok, block.call ]
      rescue StandardError => error
        [ :error, error ]
      end
    end
    @threads << thread
    thread
  end

  def wait_for_blocked(count, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      waiting = ActiveRecord::Base.uncached do
        ActiveRecord::Base.connection.select_value(
          # pg_locks is server-wide; CI's parallel workers share one server,
          # so count only backends in this test's database.
          "SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid " \
          "WHERE NOT l.granted AND l.locktype IN ('transactionid', 'tuple') AND a.datname = current_database()"
        ).to_i
      end
      break if waiting >= count
      flunk "expected #{count} blocked transaction(s), saw #{waiting}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

end
