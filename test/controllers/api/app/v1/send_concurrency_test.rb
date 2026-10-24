require "test_helper"
require "support/app_oauth_test_helper"

# #94 B, step 4b-ii: two real simultaneous sends with one client identity, on
# separate connections. Non-transactional so the unique index is actually
# contended: the first send is paused inside its acceptance transaction until
# Postgres reports the second blocked on it.
class Api::App::V1::SendConcurrencyTest < ActionDispatch::IntegrationTest

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
    # A second resident keeps this a mention room: with one resident, a human
    # message wakes it automatically and a mention is not a separate wake.
    @bystander = @account.agents.create!(name: "Bystander", system_prompt: "Test", runtime: "external")
    @chat.agent_ids = [ @agent.id, @bystander.id ]
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

    MessageDispatch.where(chat: @chat).delete_all
    AgentRuntimeInteraction.where(chat: @chat).delete_all
    @chat.messages.delete_all
    @chat.destroy!
    @agent.destroy!
  end

  test "simultaneous same-key sends make one message, one audit, one dispatch and one answer as a retry" do
    @release = Queue.new
    paused = Queue.new
    original = MessageDispatch.method(:accept!)
    first = true
    lock = Mutex.new
    pausing_accept = lambda do |**kwargs|
      pause = lock.synchronize { first.tap { first = false } }
      if pause
        paused << true
        @release.pop
      end
      original.call(**kwargs)
    end

    statuses = Queue.new
    path = "/api/app/v1/conversations/#{@chat.to_param}/messages"
    headers = bearer(@tokens)
    MessageDispatch.stub(:accept!, pausing_accept) do
      2.times do |i|
        in_thread do |_test|
          post path, params: { client_message_id: "key-00000001", content: "Hey @Grok" }, headers: headers
          statuses << response.status
        ensure
          paused << :finished
        end
        # The first send must be inside its transaction before the second starts.
        assert_equal true, paused.pop(timeout: 10), "first send never reached acceptance" if i.zero?
      end
      wait_for_blocked(1)
      @release.push(true)
      @threads.each { |thread| thread.join(10) }
    end

    assert_equal [ 200, 201 ], 2.times.map { statuses.pop }.sort
    message = @chat.messages.sole
    assert_equal 1, AuditLog.where(action: "create_message", auditable: message).count
    assert_equal 1, MessageDispatch.where(message: message).count
    assert_equal 0, AgentRuntimeInteraction.where(chat: @chat).count
  end

  test "same-key twin committed before repeat validation resolves as a retry despite a cached miss" do
    @release = Queue.new
    paused = Queue.new
    original_new = Messages::PostFromHuman.method(:new)
    first = true
    lock = Mutex.new
    pausing_new = lambda do |**options|
      service = original_new.call(**options)
      pause = lock.synchronize { first.tap { first = false } }
      if pause
        original_call = service.method(:call)
        release = @release
        service.define_singleton_method(:call) do |**arguments|
          # The request has already looked up its identity and cached nil, but
          # it has not opened its acceptance transaction or validated content.
          paused << true
          raise "twin was never released" unless release.pop(timeout: 10)

          original_call.call(**arguments)
        end
      end
      service
    end

    answers = Queue.new
    path = "/api/app/v1/conversations/#{@chat.to_param}/messages"
    headers = bearer(@tokens)
    Messages::PostFromHuman.stub(:new, pausing_new) do
      in_thread do |_test|
        post path, params: { client_message_id: "key-cache001", content: "Hey @Grok" }, headers: headers
        answers << [ response.status, response.parsed_body ]
      end
      assert_equal true, paused.pop(timeout: 10), "first request never reached the cached miss"

      # This independent request commits while the first still has its cached
      # miss. The first then sees the duplicate validator, not the unique index.
      twin = open_session
      twin.post path, params: { client_message_id: "key-cache001", content: "Hey @Grok" }, headers: headers
      assert_equal 201, twin.response.status, twin.response.body
      @release.push(true)
      @threads.each { |thread| assert thread.join(10), "paused send did not finish" }
    end

    status, body = answers.pop(timeout: 5)
    assert_equal 200, status, body.inspect
    message = @chat.messages.sole
    assert_equal 1, AuditLog.where(action: "create_message", auditable: message).count
    assert_equal 1, MessageDispatch.where(message: message).count
    assert_equal 0, AgentRuntimeInteraction.where(chat: @chat).count
  end

  private

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
