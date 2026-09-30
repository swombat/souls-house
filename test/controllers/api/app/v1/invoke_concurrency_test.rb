require "test_helper"
require "support/app_oauth_test_helper"

# #94 B, keyed-invoke extension: two real simultaneous invokes on separate
# connections. Non-transactional so the chat lock and the unique index are
# actually contended: the first invoke is paused inside its acceptance
# transaction, after reserving its run, until Postgres reports the second
# blocked on it.
class Api::App::V1::InvokeConcurrencyTest < ActionDispatch::IntegrationTest

  include AppOauthTestHelper

  self.use_transactional_tests = false

  setup do
    @user = users(:existing_user)
    @account = accounts(:existing_user_account)
    @last_session_id = Session.maximum(:id).to_i
    @last_audit_id = AuditLog.maximum(:id).to_i
    @client = create_app_client
    @tokens = sign_in_device
    @agent = @account.agents.create!(name: "Grok", system_prompt: "Test", runtime: "external")
    @chat = @account.chats.new(model_id: "openrouter/auto", title: "Race", manual_responses: true)
    @chat.agent_ids = [ @agent.id ]
    @chat.save!
  end

  teardown do
    @release&.push(true)
    @threads&.each { |thread| thread.join(5) }
    Doorkeeper::AccessToken.delete_all
    Doorkeeper::AccessGrant.delete_all
    AppSession.delete_all
    Doorkeeper::Application.delete_all
    Session.where("id > ?", @last_session_id).delete_all
    AuditLog.where("id > ?", @last_audit_id).delete_all
    return unless @chat

    AgentRuntimeInteraction.where(chat: @chat).update_all(message_dispatch_id: nil)
    MessageDispatch.where(chat: @chat).delete_all
    AgentRuntimeInteraction.where(chat: @chat).delete_all
    @chat.destroy!
    @agent.destroy!
  end

  test "simultaneous same-key invokes make one invocation and one run; the second is answered as its retry" do
    statuses = race(%w[invoke-00000001 invoke-00000001])

    assert_equal [ 202, 202 ], statuses.map(&:first)
    dispatch = MessageDispatch.where(chat: @chat).sole
    assert_equal 1, AgentRuntimeInteraction.where(chat: @chat).count
    assert_equal [ dispatch.runtime_interaction.run_id ] * 2, statuses.map { |_, body| body.dig("invocation", "runs", 0, "run_id") }
  end

  # For everyone, busy is checked under the chat lock before the row is
  # written, so the twin is refused as busy, not by the unique index; the
  # refusal must still be answered as the retry it is.
  test "simultaneous same-key invokes of everyone: one invocation, the second answered as its retry" do
    statuses = race(%w[invoke-00000001 invoke-00000001], everyone: true)

    assert_equal [ 202, 202 ], statuses.map(&:first)
    assert_equal 1, MessageDispatch.where(chat: @chat).count
    assert_equal 1, AgentRuntimeInteraction.where(chat: @chat).count
  end

  test "simultaneous invokes of everyone with different keys: the loser is 409 and leaves no row" do
    statuses = race(%w[invoke-00000001 invoke-00000002], everyone: true)

    assert_equal [ 202, 409 ], statuses.map(&:first).sort
    assert_equal 1, MessageDispatch.where(chat: @chat).count
  end

  test "simultaneous invokes with different keys: one is accepted, the loser is 409 and leaves no row" do
    statuses = race(%w[invoke-00000001 invoke-00000002])

    assert_equal [ 202, 409 ], statuses.map(&:first).sort
    assert_equal "already_responding", statuses.find { |status, _| status == 409 }.last.dig("error", "code")
    assert_equal 1, MessageDispatch.where(chat: @chat).count
    assert_equal 1, AgentRuntimeInteraction.where(chat: @chat).count
  end

  private

  def race(keys, everyone: false)
    @release = Queue.new
    paused = Queue.new
    original = AgentRuntimeInteraction.method(:reserve!)
    first = true
    lock = Mutex.new
    pausing_reserve = lambda do |**kwargs|
      interaction = original.call(**kwargs)
      pause = lock.synchronize { first.tap { first = false } }
      if pause
        paused << true
        @release.pop
      end
      interaction
    end

    results = Queue.new
    path = "/api/app/v1/conversations/#{@chat.to_param}/invoke"
    headers = bearer(@tokens)
    agent_id = everyone ? nil : @agent.to_param
    AgentRuntimeInteraction.stub(:reserve!, pausing_reserve) do
      ManualAgentResponseJob.stub(:perform_later, nil) do
        keys.each_with_index do |key, i|
          in_thread do |_test|
            post path, params: { client_invocation_id: key, agent_id: agent_id }.compact, headers: headers
            results << [ response.status, response.parsed_body ]
          ensure
            paused << :finished
          end
          assert_equal true, paused.pop(timeout: 10), "first invoke never reached its reservation" if i.zero?
        end
        wait_for_blocked(1)
        @release.push(true)
        @threads.each { |thread| thread.join(10) }
      end
    end
    keys.size.times.map { results.pop }
  end

  def in_thread(&block)
    test = self
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        test.open_session.instance_exec(test, &block)
      end
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
      flunk "expected #{count} blocked transaction(s), saw #{waiting}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

end
