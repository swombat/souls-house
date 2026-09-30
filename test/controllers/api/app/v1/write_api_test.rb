require "test_helper"
require "support/app_oauth_test_helper"

# Issue #94 B, step 4b: human writes through /api/app/v1. Sends are retry-safe
# by client identity and original-payload digest (ADR 0004); edit and delete
# follow the web's rules, delete being discard (ADR 0001).
class Api::App::V1::WriteApiTest < ActionDispatch::IntegrationTest

  include AppOauthTestHelper
  include ActiveJob::TestHelper

  setup do
    @user = users(:existing_user)
    @account = accounts(:existing_user_account)
    @client = create_app_client
    @tokens = sign_in_device
    @agent = @account.agents.create!(name: "Grok", system_prompt: "Test", runtime: "external")
    @chat = @account.chats.new(model_id: "openrouter/auto", title: "Phone chat", manual_responses: true)
    # A second resident keeps this a mention room: with one resident, a human
    # message wakes it automatically and a mention is not a separate wake.
    @bystander = @account.agents.create!(name: "Bystander", system_prompt: "Test", runtime: "external")
    @chat.agent_ids = [ @agent.id, @bystander.id ]
    @chat.save!
  end

  # --- create ----------------------------------------------------------------

  test "a first send is 201, wakes the residents it mentions, and is audited" do
    assert_enqueued_jobs 1, only: MessageDispatchJob do
      send_message("key-00000001", "Hey @Grok, from the phone")
    end
    assert_response :created
    body = response.parsed_body["message"]
    message = @chat.messages.find(body["id"])
    assert_equal [ "user", @user, "Hey @Grok, from the phone", "key-00000001" ],
                 [ message.role, message.user, message.content, message.client_message_id ]
    assert_equal "key-00000001", body["client_message_id"]
    assert_equal [ "pending", [] ], response.parsed_body["dispatch"].values_at("status", "runs")
    assert_equal @chat.reload.message_revision, body["revision"]
    audit = AuditLog.find_by!(action: "create_message", auditable: message)
    assert_equal @account, audit.account
    assert audit.data["app_session_id"].present?
  end

  test "an identical retry is 200 with the same message and wakes no one again" do
    send_message("key-00000001", "Hey @Grok")
    first = response.parsed_body["message"]

    assert_no_difference -> { Message.count } do
      assert_no_enqueued_jobs(only: MessageDispatchJob) { send_message("key-00000001", "Hey @Grok") }
    end
    assert_response :ok
    assert_equal first, response.parsed_body["message"]
  end

  test "the same identity with a different payload is 409" do
    send_message("key-00000001", "first")
    id = response.parsed_body.dig("message", "id")

    assert_no_difference -> { Message.count } do
      send_message("key-00000001", "second")
    end
    assert_error :conflict, "idempotency_conflict"
    assert_equal id, response.parsed_body.dig("error", "details", "message_id")
  end

  test "a retry after an edit returns the current message; the edited payload is a conflict" do
    send_message("key-00000001", "original")
    id = response.parsed_body.dig("message", "id")
    patch "/api/app/v1/conversations/#{@chat.to_param}/messages/#{id}", params: { content: "edited" }, headers: bearer(@tokens)
    assert_response :ok

    send_message("key-00000001", "original")
    assert_response :ok
    assert_equal "edited", response.parsed_body.dig("message", "content")

    send_message("key-00000001", "edited")
    assert_error :conflict, "idempotency_conflict"
  end

  test "a retry after a discard returns the marker and never re-creates or re-wakes" do
    send_message("key-00000001", "Hey @Grok")
    id = response.parsed_body.dig("message", "id")
    delete "/api/app/v1/conversations/#{@chat.to_param}/messages/#{id}", headers: bearer(@tokens)
    assert_response :ok

    assert_no_difference -> { Message.count } do
      assert_no_enqueued_jobs(only: MessageDispatchJob) { send_message("key-00000001", "Hey @Grok") }
    end
    assert_response :ok
    assert_equal({ "id" => id, "conversation_id" => @chat.to_param, "revision" => @chat.reload.message_revision, "discarded" => true },
                 response.parsed_body["message"])
  end

  test "a retry after membership loss is 404 and returns nothing retained" do
    team = accounts(:team_account)
    team_chat = team.chats.create!(model_id: "openrouter/auto", title: "Team")
    send_message("key-00000001", "hello team", chat: team_chat)
    assert_response :created

    memberships(:team_member).destroy!
    send_message("key-00000001", "hello team", chat: team_chat)
    assert_error :not_found, "not_found"
    assert_nil response.parsed_body["message"]
  end

  test "an archived conversation refuses a new send but still answers a retry" do
    send_message("key-00000001", "before archiving")
    @chat.update!(archived_at: Time.current)

    send_message("key-00000001", "before archiving")
    assert_response :ok
    send_message("key-00000002", "after archiving")
    assert_error :unprocessable_entity, "conversation_not_respondable"
  end

  test "the identity is scoped to the conversation" do
    other = @account.chats.create!(model_id: "openrouter/auto", title: "Other")
    send_message("key-00000001", "here")
    send_message("key-00000001", "there", chat: other)
    assert_response :created
  end

  test "malformed identity or content is 422 before anything is written" do
    assert_no_difference -> { Message.count } do
      send_message("short", "hi")
      assert_error :unprocessable_entity, "invalid_parameter"
      assert_equal "client_message_id", response.parsed_body.dig("error", "details", "parameter")
      send_message("key-00000001", "")
      assert_error :unprocessable_entity, "invalid_parameter"
      assert_equal "content", response.parsed_body.dig("error", "details", "parameter")
    end
  end

  test "a new identity repeating the last message is refused as the web refuses it" do
    send_message("key-00000001", "same words")
    send_message("key-00000002", "same words")
    assert_error :unprocessable_entity, "duplicate_message"
  end

  # The race: a twin with the same identity commits between this request's
  # lookup and its save. Both ways it can lose are a retry, never a refusal
  # and never a second wake.
  test "losing a race to a twin on the repeat guard answers as a retry" do
    assert_race_answered_as_retry(twin_content: "Hey @Grok")
  end

  test "losing a race to a twin on the unique index answers as a retry" do
    # A later message makes the repeat guard pass, so the insert reaches the index.
    assert_race_answered_as_retry(twin_content: "Hey @Grok", followed_by: "something after")
  end

  # --- the wake (#94 B, step 4b-ii) ---------------------------------------------

  test "a mention while live activity is off is a structured 503 and nothing is written" do
    with_live_activity_off do
      assert_no_difference [ "Message.count", "MessageDispatch.count", "AuditLog.count" ] do
        send_message("key-00000001", "Hey @Grok")
      end
      assert_error :service_unavailable, "dispatch_unavailable"
      assert response.parsed_body.dig("error", "details", "retryable")

      send_message("key-00000002", "no mention")
      assert_response :created
      assert_nil response.parsed_body["dispatch"]
    end
  end

  test "a failure before commit is 503 send_failed, and the same key then creates afresh" do
    MessageDispatch.stub(:accept!, ->(**) { raise "synthetic" }) do
      assert_no_difference [ "Message.count", "MessageDispatch.count", "AuditLog.count" ] do
        send_message("key-00000001", "Hey @Grok")
      end
    end
    assert_error :service_unavailable, "send_failed"

    send_message("key-00000001", "Hey @Grok")
    assert_response :created
  end

  test "a failed enqueue after commit is still 201, and a later retry creates and re-drives nothing" do
    MessageDispatchJob.stub(:perform_later, ->(*) { raise "queue down" }) do
      send_message("key-00000001", "Hey @Grok")
    end
    assert_response :created
    assert_equal "pending", response.parsed_body.dig("dispatch", "status")

    travel 31.seconds do
      assert_no_difference [ "Message.count", "MessageDispatch.count", "AuditLog.count" ] do
        assert_no_enqueued_jobs { send_message("key-00000001", "Hey @Grok") }
      end
    end
    assert_response :ok
  end

  test "the author reads where the wake stands, including after discard" do
    send_message("key-00000001", "Hey @Grok")
    id = response.parsed_body.dig("message", "id")
    get "/api/app/v1/conversations/#{@chat.to_param}/messages/#{id}/dispatch", headers: bearer(@tokens)
    assert_response :ok
    assert_equal "pending", response.parsed_body.dig("dispatch", "status")

    delete "/api/app/v1/conversations/#{@chat.to_param}/messages/#{id}", headers: bearer(@tokens)
    get "/api/app/v1/conversations/#{@chat.to_param}/messages/#{id}/dispatch", headers: bearer(@tokens)
    assert_equal %w[cancelled discarded], response.parsed_body["dispatch"].values_at("status", "reason")
  end

  test "only the author may read a wake's status" do
    other = users(:user_1)
    message = @chat.messages.create!(role: "user", user: other, content: "someone else's")
    get "/api/app/v1/conversations/#{@chat.to_param}/messages/#{message.to_param}/dispatch", headers: bearer(@tokens)
    assert_error :forbidden, "forbidden"
  end

  # --- edit and delete -------------------------------------------------------

  test "the author edits a message, taking a revision and keeping its identity" do
    send_message("key-00000001", "typo")
    body = response.parsed_body["message"]

    patch "/api/app/v1/conversations/#{@chat.to_param}/messages/#{body['id']}", params: { content: "fixed" }, headers: bearer(@tokens)
    assert_response :ok
    edited = response.parsed_body["message"]
    assert_equal "fixed", edited["content"]
    assert_operator edited["revision"], :>, body["revision"]
    message = @chat.messages.find(body["id"])
    assert_equal [ "key-00000001", Messages::PostFromHuman.submission_digest(content: "typo") ],
                 [ message.client_message_id, message.submission_digest ]
    assert AuditLog.exists?(action: "update_message", auditable: message)
  end

  test "no write path can change a sent message's identity" do
    send_message("key-00000001", "sent")
    message = @chat.messages.find(response.parsed_body.dig("message", "id"))
    assert_not message.update(client_message_id: "key-99999999")
    assert_not message.reload.update(submission_digest: "v1:forged")
    assert_equal "key-00000001", message.reload.client_message_id
  end

  test "delete is discard, audited, and a repeat returns the same marker" do
    send_message("key-00000001", "regret")
    id = response.parsed_body.dig("message", "id")

    delete "/api/app/v1/conversations/#{@chat.to_param}/messages/#{id}", headers: bearer(@tokens)
    assert_response :ok
    marker = response.parsed_body["message"]
    assert_equal true, marker["discarded"]
    assert_nil marker["content"]
    message = @chat.messages.find(id)
    assert message.discarded?
    assert_equal "regret", message.content

    delete "/api/app/v1/conversations/#{@chat.to_param}/messages/#{id}", headers: bearer(@tokens)
    assert_response :ok
    assert_equal marker, response.parsed_body["message"]
    assert_equal 1, AuditLog.where(action: "delete_message", auditable: message).count
  end

  test "a discarded message cannot be edited" do
    message = @chat.messages.create!(role: "user", user: @user, content: "gone")
    message.discard!
    patch "/api/app/v1/conversations/#{@chat.to_param}/messages/#{message.to_param}", params: { content: "back" }, headers: bearer(@tokens)
    assert_error :not_found, "not_found"
  end

  test "only the author may edit or delete, with no site-admin override" do
    resident = @chat.messages.create!(role: "assistant", agent: @agent, content: "resident words")
    someone = @chat.messages.create!(role: "user", user: users(:site_admin_user), content: "admin words")
    [ resident, someone ].each do |message|
      patch "/api/app/v1/conversations/#{@chat.to_param}/messages/#{message.to_param}", params: { content: "mine now" }, headers: bearer(@tokens)
      assert_error :forbidden, "forbidden"
      delete "/api/app/v1/conversations/#{@chat.to_param}/messages/#{message.to_param}", headers: bearer(@tokens)
      assert_error :forbidden, "forbidden"
      assert_not message.reload.discarded?
    end

    @user.update!(is_site_admin: true)
    delete "/api/app/v1/conversations/#{@chat.to_param}/messages/#{resident.to_param}", headers: bearer(@tokens)
    assert_error :forbidden, "forbidden"
  end

  test "a message is only reachable through its own conversation" do
    other = @account.chats.create!(model_id: "openrouter/auto", title: "Other")
    message = other.messages.create!(role: "user", user: @user, content: "elsewhere")
    delete "/api/app/v1/conversations/#{@chat.to_param}/messages/#{message.to_param}", headers: bearer(@tokens)
    assert_error :not_found, "not_found"
    assert_not message.reload.discarded?
  end

  private

  def send_message(client_message_id, content, chat: @chat)
    post "/api/app/v1/conversations/#{chat.to_param}/messages",
         params: { client_message_id: client_message_id, content: content }, headers: bearer(@tokens)
  end

  def assert_race_answered_as_retry(twin_content:, followed_by: nil)
    chat = @chat
    user = @user
    original_new = Messages::PostFromHuman.method(:new)
    twin = nil
    racing_new = lambda do |**kwargs|
      twin = chat.messages.create!(role: "user", user: user, content: twin_content, client_message_id: "key-00000001",
                                   submission_digest: Messages::PostFromHuman.submission_digest(content: twin_content))
      chat.messages.create!(role: "assistant", agent: @agent, content: followed_by) if followed_by
      original_new.call(**kwargs)
    end

    Messages::PostFromHuman.stub(:new, racing_new) do
      assert_no_enqueued_jobs(only: MessageDispatchJob) { send_message("key-00000001", twin_content) }
    end
    assert_response :ok
    assert_equal twin.to_param, response.parsed_body.dig("message", "id")
    assert_equal 1, chat.messages.where(client_message_id: "key-00000001").count
  end

  def with_live_activity_off
    previous = ENV["SOULSHOUSE_LIVE_ACTIVITY"]
    ENV["SOULSHOUSE_LIVE_ACTIVITY"] = "0"
    yield
  ensure
    ENV["SOULSHOUSE_LIVE_ACTIVITY"] = previous
  end

  def assert_error(status, code)
    assert_response status
    assert_equal code, response.parsed_body.dig("error", "code")
    assert response.parsed_body.dig("error", "request_id").present?
  end

end
