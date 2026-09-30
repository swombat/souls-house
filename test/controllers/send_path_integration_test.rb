require "test_helper"
require "support/app_oauth_test_helper"

# #97 rebased onto master: one send path for drafts, the sole-resident
# automatic wake and mention dispatch (Mira's integration boundaries, #97).
class SendPathIntegrationTest < ActionDispatch::IntegrationTest

  include AppOauthTestHelper
  include ActiveJob::TestHelper

  setup do
    Setting.instance.update!(allow_chats: true)
  end

  # --- one wake per send, every entry point ---------------------------------

  test "web send in a one-resident room is one automatic wake, even with a mention" do
    user, chat, resident = solo_room(users(:user_1), accounts(:personal_account))
    web_login(user)

    assert_enqueued_jobs 1, only: [ ManualAgentResponseJob, AllAgentsResponseJob ] do
      post account_chat_messages_path(chat.account, chat), params: { message: { content: "Hello @Solo" } }, as: :json
    end

    assert_response :created
    assert_one_automatic_wake(chat, resident)
  end

  test "app send in a one-resident room is one automatic wake, even with a mention" do
    user = @user = users(:existing_user)
    _, chat, resident = solo_room(user, accounts(:existing_user_account))
    @client = create_app_client
    tokens = sign_in_device

    assert_enqueued_jobs 1, only: [ ManualAgentResponseJob, AllAgentsResponseJob ] do
      post "/api/app/v1/conversations/#{chat.to_param}/messages",
           params: { client_message_id: "solo-0001", content: "Hello @Solo" }, headers: bearer(tokens)
    end

    assert_response :created
    assert_one_automatic_wake(chat, resident)
  end

  test "API send in a one-resident room is one automatic wake and reports it" do
    user = users(:confirmed_user)
    token = ApiKey.generate_for(user, name: "Test").raw_token
    _, chat, resident = solo_room(user, user.personal_account)

    assert_enqueued_jobs 1, only: [ ManualAgentResponseJob, AllAgentsResponseJob ] do
      post api_v1_conversation_messages_url(chat), params: { content: "Hello @Solo" },
           headers: { "Authorization" => "Bearer #{token}" }
    end

    assert_response :created
    assert response.parsed_body["ai_response_triggered"]
    assert_one_automatic_wake(chat, resident)
  end

  test "an opening message is one automatic wake" do
    user = users(:user_1)
    resident = user.personal_account.agents.create!(name: "Solo", system_prompt: "Test", runtime: "external")

    chat = nil
    assert_enqueued_jobs 1, only: [ ManualAgentResponseJob, AllAgentsResponseJob ] do
      chat = Chat.create_with_message!({ account: user.personal_account, title: "Opening", manual_responses: true },
        message_content: "Hello @Solo", user: user, agent_ids: [ resident.id ])
    end

    assert_one_automatic_wake(chat, resident)
  end

  test "a room with two residents keeps mention dispatch and writes no automatic wake" do
    user, chat, resident = solo_room(users(:user_1), accounts(:personal_account))
    chat.agents << user.personal_account.agents.create!(name: "Other", system_prompt: "Test", runtime: "external")
    web_login(user)

    post account_chat_messages_path(chat.account, chat), params: { message: { content: "Hello @Solo" } }, as: :json

    dispatch = chat.messages.last.message_dispatch
    assert_equal "mention", dispatch.kind
    assert_equal [ resident.id ], dispatch.target_agent_ids
    assert_equal 1, MessageDispatch.where(chat: chat).count
  end

  test "the automatic wake is reserved before the send returns and never called a mention" do
    user, chat, resident = solo_room(users(:user_1), accounts(:personal_account))
    web_login(user)

    post account_chat_messages_path(chat.account, chat), params: { message: { content: "No mention at all" } }, as: :json

    dispatch = chat.messages.last.message_dispatch
    assert_equal "automatic", dispatch.kind
    assert_equal "reserved", dispatch.status
    assert chat.agent_response_active?(resident)
    assert_equal "automatic", dispatch.as_app_json[:kind]
  end

  test "a failed inline reservation still accepts the send and leaves the wake for the sweeper" do
    user, chat, = solo_room(users(:user_1), accounts(:personal_account))
    web_login(user)

    AgentRuntimeInteraction.stub(:reserve!, ->(**) { raise ActiveRecord::ConnectionTimeoutError, "synthetic" }) do
      post account_chat_messages_path(chat.account, chat), params: { message: { content: "Hello" } }, as: :json
    end

    assert_response :created
    dispatch = chat.messages.last.message_dispatch
    assert_equal "pending", dispatch.status

    travel MessageDispatch::REDRIVE_GRACE + 1.second do
      assert_enqueued_jobs 1, only: MessageDispatchJob do
        dispatch.redrive!
      end
    end
  end

  test "duplicate delivery of the automatic wake reserves one run" do
    user, chat, = solo_room(users(:user_1), accounts(:personal_account))
    message = nil
    AgentRuntimeInteraction.stub(:reserve!, ->(**) { raise ActiveRecord::ConnectionTimeoutError, "synthetic" }) do
      message = chat.messages.create!(role: "user", user: user, content: "Hello")
    end
    dispatch = message.message_dispatch
    assert_equal "pending", dispatch.status

    assert_difference "AgentRuntimeInteraction.count", 1 do
      3.times { MessageDispatchJob.perform_now(dispatch) }
    end
    assert_equal "reserved", dispatch.reload.status
  end

  test "discard before claim cancels the automatic wake" do
    user, chat, = solo_room(users(:user_1), accounts(:personal_account))
    message = chat.messages.create!(role: "user", user: user, content: "Hello")
    run = message.message_dispatch.runtime_interaction

    message.discard_as_author!

    assert_equal "cancelled", message.message_dispatch.reload.status
    assert_equal "discarded", message.message_dispatch.reason
    assert_equal "cancelled", run.reload.execution_state
  end

  test "live activity off keeps master's direct wake, with no dispatch, including with async turns on" do
    user, chat, = solo_room(users(:user_1), accounts(:personal_account))
    web_login(user)

    with_env("SOULSHOUSE_LIVE_ACTIVITY" => "0", "SOULSHOUSE_ASYNC_TURNS" => "1") do
      assert_enqueued_jobs 1, only: ManualAgentResponseJob do
        post account_chat_messages_path(chat.account, chat), params: { message: { content: "Hello @Solo" } }, as: :json
      end
    end

    assert_response :created
    assert_equal 0, MessageDispatch.where(chat: chat).count
    assert_equal 1, enqueued_jobs.count { |job| job["job_class"] == "ManualAgentResponseJob" }
  end

  # --- drafts inside the acceptance transaction ------------------------------

  test "a stale draft sends nothing, wakes nothing and keeps the draft" do
    user, chat, = solo_room(users(:user_1), accounts(:personal_account))
    web_login(user)
    draft = ConversationDraft.for(chat: chat, user: user)
    draft.replace!(content: "keep me", revision: 0)

    assert_no_difference [ "Message.count", "MessageDispatch.count", "AgentRuntimeInteraction.count" ] do
      post account_chat_messages_path(chat.account, chat),
           params: { message: { content: "keep me" }, draft_revision: 0 }, as: :json
    end

    assert_response :conflict
    assert_equal({ "content" => "keep me", "revision" => 1 }, response.parsed_body["draft"])
    assert_equal "keep me", draft.reload.content
  end

  test "a failed dispatch write rolls back the message and keeps the draft" do
    user, chat, = solo_room(users(:user_1), accounts(:personal_account))
    chat.agents << user.personal_account.agents.create!(name: "Other", system_prompt: "Test", runtime: "external")
    web_login(user)
    draft = ConversationDraft.for(chat: chat, user: user)
    draft.replace!(content: "Hello @Solo", revision: 0)

    MessageDispatch.stub(:accept!, ->(**) { raise ActiveRecord::StatementInvalid, "synthetic dispatch failure" }) do
      assert_no_difference [ "Message.count", "AuditLog.count" ] do
        post account_chat_messages_path(chat.account, chat),
             params: { message: { content: "Hello @Solo" }, draft_revision: 1 }, as: :json
      end
    end

    assert_response :unprocessable_entity
    assert_equal({ "content" => "Hello @Solo", "revision" => 1 }, draft.reload.as_json.transform_keys(&:to_s))
  end

  test "a failed automatic-wake write rolls back the message and keeps the draft" do
    user, chat, = solo_room(users(:user_1), accounts(:personal_account))
    web_login(user)
    draft = ConversationDraft.for(chat: chat, user: user)
    draft.replace!(content: "Hello", revision: 0)

    MessageDispatch.stub(:accept!, ->(**) { raise ActiveRecord::StatementInvalid, "synthetic dispatch failure" }) do
      assert_no_difference "Message.count" do
        post account_chat_messages_path(chat.account, chat),
             params: { message: { content: "Hello" }, draft_revision: 1 }, as: :json
      end
    end

    assert_response :unprocessable_entity
    assert_equal "Hello", draft.reload.content
  end

  test "a successful send clears the draft in the same commit as the wake" do
    user, chat, = solo_room(users(:user_1), accounts(:personal_account))
    web_login(user)
    ConversationDraft.for(chat: chat, user: user).replace!(content: "Hello", revision: 0)

    post account_chat_messages_path(chat.account, chat), params: { message: { content: "Hello" }, draft_revision: 1 }, as: :json

    assert_response :created
    assert_equal({ "content" => "", "revision" => 2 }, response.parsed_body["draft"])
    assert_equal "automatic", chat.messages.last.message_dispatch.kind
  end

  test "a native send leaves the author's web draft alone" do
    user = @user = users(:existing_user)
    _, chat, = solo_room(user, accounts(:existing_user_account))
    ConversationDraft.for(chat: chat, user: user).replace!(content: "half written", revision: 0)
    @client = create_app_client
    tokens = sign_in_device

    post "/api/app/v1/conversations/#{chat.to_param}/messages",
         params: { client_message_id: "native-0001", content: "from the phone" }, headers: bearer(tokens)

    assert_response :created
    assert_equal "half written", ConversationDraft.find_by!(chat: chat, user: user).content
  end

  private

  def solo_room(user, account)
    resident = account.agents.create!(name: "Solo", system_prompt: "Test", runtime: "external")
    chat = account.chats.new(model_id: "openrouter/auto", title: "Solo room", manual_responses: true)
    chat.agent_ids = [ resident.id ]
    chat.save!
    [ user, chat, resident ]
  end

  def web_login(user)
    post login_path, params: { email_address: user.email_address, password: "password123" }
  end

  def assert_one_automatic_wake(chat, resident)
    dispatches = MessageDispatch.where(chat: chat)
    assert_equal 1, dispatches.count
    assert_equal "automatic", dispatches.sole.kind
    assert_equal [ resident.id ], dispatches.sole.target_agent_ids
    assert_equal 1, chat.agent_runtime_interactions.count
  end

  def with_env(values)
    previous = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

end
