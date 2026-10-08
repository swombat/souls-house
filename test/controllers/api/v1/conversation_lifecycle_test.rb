require "test_helper"

# Archive, delete/restore, fork, resident assignment and model/web-access
# changes through a person's key, mirroring chats/* on the web.
class Api::V1::ConversationLifecycleTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Lifecycle")
    @key = ApiKey.generate_for(@user, name: "Person's agent", account: @account)
    @headers = { "Authorization" => "Bearer #{@key.raw_token}" }
    @agent = agents(:research_assistant)
    @resident_headers = { "Authorization" => "Bearer #{ApiKey.generate_for(@user, name: "Resident", agent: @agent).raw_token}" }
    @foreign_chat = accounts(:existing_user_account).chats.create!(model_id: "openrouter/auto", title: "Foreign")
  end

  def listed_ids(filter = nil, headers: @headers)
    get api_v1_conversations_path, params: { filter: filter }.compact, headers: headers
    response.parsed_body.fetch("conversations").map { |c| c["id"] }
  end

  # -- archive ---------------------------------------------------------------

  test "a member archives and unarchives, with the web's audit entries" do
    assert_difference -> { AuditLog.where(action: "archive_chat", auditable: @chat).count } do
      post api_v1_conversation_archive_path(@chat), headers: @headers, as: :json
    end
    assert_response :success
    assert response.parsed_body.dig("conversation", "archived")
    assert @chat.reload.archived?
    assert_equal @key.id, AuditLog.where(action: "archive_chat").last.data["api_key_id"]
    assert_not_includes listed_ids, @chat.to_param
    assert_includes listed_ids("archived"), @chat.to_param

    assert_difference -> { AuditLog.where(action: "unarchive_chat", auditable: @chat).count } do
      delete api_v1_conversation_archive_path(@chat), headers: @headers, as: :json
    end
    assert_response :success
    assert_not response.parsed_body.dig("conversation", "archived")
    assert_not @chat.reload.archived?
  end

  test "archive is 404 for another account's conversation and 403 for a resident key" do
    post api_v1_conversation_archive_path(@foreign_chat), headers: @headers, as: :json
    assert_response :not_found
    assert_not @foreign_chat.reload.archived?

    @chat.agents << @agent
    post api_v1_conversation_archive_path(@chat), headers: @resident_headers, as: :json
    assert_response :forbidden
    assert_not @chat.reload.archived?
  end

  test "a key whose person is no longer a confirmed member reaches nothing" do
    Membership.find_by!(user: @user, account: @account).update_columns(confirmed_at: nil)
    post api_v1_conversation_archive_path(@chat), headers: @headers, as: :json
    assert_response :not_found
    assert_not @chat.reload.archived?
  end

  # -- delete / restore ------------------------------------------------------

  test "a manager deletes, finds and restores a conversation; repeats are no-ops" do
    assert_difference -> { AuditLog.where(action: "discard_chat").count }, 1 do
      2.times do
        post api_v1_conversation_discard_path(@chat), headers: @headers, as: :json
        assert_response :success
        assert response.parsed_body.dig("conversation", "deleted")
      end
    end
    assert @chat.reload.discarded?
    assert_not_includes listed_ids, @chat.to_param
    assert_includes listed_ids("deleted"), @chat.to_param

    assert_difference -> { AuditLog.where(action: "restore_chat").count }, 1 do
      2.times do
        delete api_v1_conversation_discard_path(@chat), headers: @headers, as: :json
        assert_response :success
      end
    end
    assert_not @chat.reload.discarded?
    assert_not_includes listed_ids("deleted"), @chat.to_param
  end

  # Every confirmed member can manage today (Account#manageable_by?), so the
  # refusal is exercised by making the rule say no.
  def with_unmanageable_accounts
    original = Account.instance_method(:manageable_by?)
    Account.define_method(:manageable_by?) { |_user| false }
    yield
  ensure
    Account.define_method(:manageable_by?, original)
  end

  test "delete is 403 for someone who cannot manage the account" do
    with_unmanageable_accounts do
      post api_v1_conversation_discard_path(@chat), headers: @headers, as: :json
      assert_response :forbidden
      assert_match(/manage this account/, response.parsed_body["error"])
      get api_v1_conversations_path, params: { filter: "deleted" }, headers: @headers
      assert_response :forbidden
    end
    assert_not @chat.reload.discarded?
  end

  test "delete is 404 for another account and 403 for a resident key" do
    post api_v1_conversation_discard_path(@foreign_chat), headers: @headers, as: :json
    assert_response :not_found
    @chat.agents << @agent
    post api_v1_conversation_discard_path(@chat), headers: @resident_headers, as: :json
    assert_response :forbidden
    assert_not @chat.reload.discarded?
  end

  test "listing filters are validated and archived/deleted are person-only" do
    get api_v1_conversations_path, params: { filter: "everything" }, headers: @headers
    assert_response :unprocessable_entity
    get api_v1_conversations_path, params: { filter: "deleted" }, headers: @resident_headers
    assert_response :forbidden
    get api_v1_conversations_path, params: { filter: "archived" }, headers: @resident_headers
    assert_response :forbidden
    get api_v1_conversations_path, headers: @resident_headers
    assert_response :success
  end

  # -- fork ------------------------------------------------------------------

  def resident_room
    room = @account.chats.new(model_id: "openrouter/auto", title: "Lifecycle", manual_responses: true)
    room.agent_ids = [ @agent.id ]
    room.save!
    room
  end

  test "a member forks with the web's default title or a chosen one" do
    @chat = resident_room
    @chat.messages.create!(role: "assistant", agent: @agent, content: "Keep this")

    post api_v1_conversation_fork_path(@chat), headers: @headers, as: :json
    assert_response :created
    forked = Chat.find(response.parsed_body.dig("conversation", "id"))
    assert_equal "Lifecycle (Fork)", forked.title
    assert_equal [ "Keep this" ], forked.messages.pluck(:content)
    assert_equal [ @agent ], forked.agents.to_a
    assert_equal @chat.to_param, response.parsed_body["source_conversation_id"]
    assert AuditLog.exists?(action: "fork_chat", auditable: forked)

    post api_v1_conversation_fork_path(@chat), params: { title: "  Branch  " }, headers: @headers, as: :json
    assert_response :created
    assert_equal "Branch", response.parsed_body.dig("conversation", "title")
  end

  test "fork refuses a bad title, another account and a resident key" do
    @chat = resident_room
    assert_no_difference -> { Chat.count } do
      post api_v1_conversation_fork_path(@chat), params: { title: "x" * 256 }, headers: @headers, as: :json
      assert_response :unprocessable_entity
      post api_v1_conversation_fork_path(@foreign_chat), headers: @headers, as: :json
      assert_response :not_found
      post api_v1_conversation_fork_path(@chat), headers: @resident_headers, as: :json
      assert_response :forbidden
    end
  end

  # -- resident assignment ---------------------------------------------------

  test "a member hands a bare-model conversation to a resident" do
    assert_difference -> { @chat.messages.count } do
      post api_v1_conversation_agent_assignment_path(@chat), params: { agent_id: @agent.to_param }, headers: @headers, as: :json
    end
    assert_response :success
    assert_equal @agent.to_param, response.parsed_body.dig("agent", "id")
    @chat.reload
    assert @chat.manual_responses?
    assert_includes @chat.agents, @agent
    assert_match(/now being handled by #{@agent.name}/, @chat.messages.last.content)
    assert AuditLog.exists?(action: "assign_agent_to_chat", auditable: @chat)

    post api_v1_conversation_agent_assignment_path(@chat), params: { agent_id: agents(:code_reviewer).to_param }, headers: @headers, as: :json
    assert_response :conflict
    assert_equal "already_assigned", response.parsed_body["code"]
  end

  test "assignment refuses a missing agent_id, another account's resident or room, and a resident key" do
    post api_v1_conversation_agent_assignment_path(@chat), params: {}, headers: @headers, as: :json
    assert_response :unprocessable_entity
    post api_v1_conversation_agent_assignment_path(@chat), params: { agent_id: agents(:other_account_agent).to_param }, headers: @headers, as: :json
    assert_response :not_found
    post api_v1_conversation_agent_assignment_path(@foreign_chat), params: { agent_id: @agent.to_param }, headers: @headers, as: :json
    assert_response :not_found
    post api_v1_conversation_agent_assignment_path(@chat), params: { agent_id: @agent.to_param }, headers: @resident_headers, as: :json
    assert_response :forbidden
    assert_not @chat.reload.manual_responses?
  end

  # -- model and web access (chats#update) -----------------------------------

  test "a person changes the model and web access" do
    patch api_v1_conversation_path(@chat), params: { model_id: "anthropic/claude-opus-4", web_access: true }, headers: @headers, as: :json
    assert_response :success
    assert_equal "anthropic/claude-opus-4", response.parsed_body.dig("conversation", "model_id")
    assert_equal true, response.parsed_body.dig("conversation", "web_access")
    @chat.reload
    assert_equal "anthropic/claude-opus-4", @chat.model_id
    assert @chat.web_access
  end

  test "model and web access changes are validated and refused to a resident key" do
    patch api_v1_conversation_path(@chat), params: { web_access: "yes" }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    patch api_v1_conversation_path(@chat), params: { model_id: "  " }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    patch api_v1_conversation_path(@foreign_chat), params: { web_access: true }, headers: @headers, as: :json
    assert_response :not_found

    @chat.agents << @agent
    patch api_v1_conversation_path(@chat), params: { web_access: true }, headers: @resident_headers, as: :json
    assert_response :forbidden
    patch api_v1_conversation_path(@chat), params: { title: "Renamed", model_id: "anthropic/claude-opus-4" }, headers: @resident_headers, as: :json
    assert_response :forbidden
    @chat.reload
    assert_not @chat.web_access
    assert_equal "Lifecycle", @chat.title
    assert_equal "openrouter/auto", @chat.model_id
  end

end
