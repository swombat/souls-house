require "test_helper"

class Api::V1::ResidentConversationArchivesTest < ActionDispatch::IntegrationTest

  setup do
    @agent = agents(:research_assistant)
    @user = users(:confirmed_user)
    @chat = @agent.account.chats.create!(title: "Idle", manual_responses: true, agents: [ @agent ], model_id: "openrouter/auto")
    @token = ApiKey.generate_for(@user, name: "Archive", agent: @agent).raw_token
  end

  test "a resident archives and unarchives an idle conversation, audited as the resident" do
    assert_difference -> { AuditLog.where(action: "archive_chat").count } do
      post "/api/v1/conversations/#{@chat.to_param}/archive", headers: auth
    end
    assert_response :success
    assert @chat.reload.archived?
    log = AuditLog.where(action: "archive_chat").last
    assert_nil log.user_id
    assert_equal "resident", log.data["by"]
    assert_equal @agent.id, log.data["agent_id"]

    delete "/api/v1/conversations/#{@chat.to_param}/archive", headers: auth
    assert_response :success
    assert_not @chat.reload.archived?
    assert_equal 1, AuditLog.where(action: "unarchive_chat", auditable: @chat).count
  end

  test "an open reply expectation, anyone's, refuses with the list" do
    ask = @chat.messages.create!(role: "user", user: @user, content: "Can you check this?")
    ReplyExpectation.create!(message: ask, user: @user, score: 0.9, classifier_version: "test")

    post "/api/v1/conversations/#{@chat.to_param}/archive", headers: auth
    assert_response :conflict
    assert_equal "conversation_has_pending_work", response.parsed_body["code"]
    assert_equal [ ask.to_param ], response.parsed_body["open_reply_expectations"].map { _1["message_id"] }
    assert_not @chat.reload.archived?
    assert ReplyExpectation.last.state_open?
  end

  test "a scheduled commitment refuses; a cancelled one does not" do
    commitment = Commitment.create!(agent: @agent, source_chat: @chat, text: "Look at the receipt", due_at: 1.hour.from_now)

    post "/api/v1/conversations/#{@chat.to_param}/archive", headers: auth
    assert_response :conflict
    assert_equal [ commitment.to_param ], response.parsed_body["scheduled_commitments"].map { _1["id"] }
    assert_not @chat.reload.archived?

    commitment.update!(status: "cancelled", cancelled_at: Time.current)
    post "/api/v1/conversations/#{@chat.to_param}/archive", headers: auth
    assert_response :success
    assert @chat.reload.archived?
  end

  test "manual human archive still dismisses expectations despite pending work" do
    ask = @chat.messages.create!(role: "user", user: @user, content: "Can you check this?")
    expectation = ReplyExpectation.create!(message: ask, user: @user, score: 0.9, classifier_version: "test")
    commitment = Commitment.create!(agent: @agent, source_chat: @chat, text: "Look at the receipt", due_at: 1.hour.from_now)
    human = @chat.account.owner
    human_token = ApiKey.generate_for(human, name: "Manual archive").raw_token

    post "/api/v1/conversations/#{@chat.to_param}/archive", headers: { "Authorization" => "Bearer #{human_token}" }

    assert_response :success
    assert @chat.reload.archived?
    assert expectation.reload.state_dismissed?
    assert commitment.reload.scheduled?
    assert_equal human, AuditLog.where(action: "archive_chat", auditable: @chat).last.user
  end

  test "another resident's commitment is listed by headline, never its private text" do
    other = agents(:code_reviewer)
    @chat.agents << other
    Commitment.create!(agent: other, source_chat: @chat, summary: "Check the receipt",
      text: "PRIVATE brief: the account number is 1234", due_at: 1.hour.from_now)

    post "/api/v1/conversations/#{@chat.to_param}/archive", headers: auth
    assert_response :conflict
    listed = response.parsed_body["scheduled_commitments"].sole
    assert_equal "Check the receipt", listed["headline"]
    assert_equal other.name, listed["resident"]
    assert_not_includes response.body, "PRIVATE"
  end

  test "an activated commitment whose wake is still held here refuses, even if made elsewhere" do
    elsewhere = @agent.account.chats.create!(title: "Source", manual_responses: true, agents: [ @agent ], model_id: "openrouter/auto")
    commitment = Commitment.create!(agent: @agent, source_chat: elsewhere, text: "Come back", due_at: 1.minute.from_now)
    commitment.update_columns(status: "activated", activation_chat_id: @chat.id, wake_state: "held", activated_at: Time.current)

    post "/api/v1/conversations/#{@chat.to_param}/archive", headers: auth
    assert_response :conflict
    assert_equal [ commitment.to_param ], response.parsed_body["scheduled_commitments"].map { _1["id"] }

    commitment.update_columns(wake_state: "delivered")
    post "/api/v1/conversations/#{@chat.to_param}/archive", headers: auth
    assert_response :success
  end

  test "the owed check runs under the chat lock, so an expectation cannot slip in before archive" do
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] unless payload[:name] == "SCHEMA"
    end
    post "/api/v1/conversations/#{@chat.to_param}/archive", headers: auth
    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert_response :success
    lock_at = statements.index { _1.match?(/FROM "chats".*FOR UPDATE/m) }
    check_at = statements.index { _1.match?(/FROM "reply_expectations"/) }
    assert lock_at, "expected the chat row to be locked"
    assert check_at, "expected the reply-expectation check"
    assert_operator lock_at, :<, check_at, "the owed check must run after the chat lock is taken"
  end

  test "a conversation the resident is not in is not found" do
    other = @agent.account.chats.create!(title: "Elsewhere", manual_responses: true, agents: [ agents(:code_reviewer) ], model_id: "openrouter/auto")
    post "/api/v1/conversations/#{other.to_param}/archive", headers: auth
    assert_response :not_found
    assert_not other.reload.archived?
  end

  private

  def auth
    { "Authorization" => "Bearer #{@token}" }
  end

end
