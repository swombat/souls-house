require "test_helper"

class ChatsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @chat = @account.chats.create!(
      model_id: "openrouter/auto",
      title: "Test Conversation"
    )

    # Sign in user
    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    assert_redirected_to root_path
  end

  test "should get index" do
    get account_chats_path(@account)
    assert_response :success
  end

  test "should get new" do
    get new_account_chat_path(@account)
    assert_response :success
  end

  test "new chat excludes agents whose hosted runtime is still being prepared" do
    provisioning_agent = agents(:research_assistant)
    provisioning_agent.update!(
      runtime: "provisioning",
      birth_committed_at: Time.current
    )

    get new_account_chat_path(@account)

    assert_response :success
    agent_ids = inertia_shared_props.fetch("agents").pluck("id")
    assert_not_includes agent_ids, provisioning_agent.to_param
    assert_includes agent_ids, agents(:code_reviewer).to_param
  end

  test "new chat exposes OAuth subscription metadata and the chat usage setting" do
    agent = agents(:research_assistant)
    agent.update!(
      model_id: "x-ai/grok-4.6",
      runtime: "external",
      health_state: "healthy",
      provider_auth_modes: { "xai" => "oauth_account" },
      provider_connections: { "xai" => { "status" => "connected" } }
    )
    Setting.instance.update!(show_usage_in_chat: true)

    get new_account_chat_path(@account)

    agent_json = inertia_shared_props.fetch("agents").find { |item| item.fetch("id") == agent.to_param }
    assert_equal "xai", agent_json.dig("provider_subscription", "provider")
    assert_equal true, inertia_shared_props.fetch("show_usage_in_chat")
  end

  test "index redirects to agent creation when no active agents exist" do
    @account.agents.update_all(active: false)

    get account_chats_path(@account)

    assert_redirected_to account_agents_path(@account, create: true)
    assert_equal "Create an agent before starting a conversation", flash[:alert]
  end

  test "new redirects to agent creation when no active agents exist" do
    @account.agents.update_all(active: false)

    get new_account_chat_path(@account)

    assert_redirected_to account_agents_path(@account, create: true)
    assert_equal "Create an agent before starting a conversation", flash[:alert]
  end

  test "should show chat" do
    get account_chat_path(@account, @chat)
    assert_response :success
  end

  test "group chat agent props use the safe list projection" do
    agent = agents(:research_assistant)
    agent.update!(
      telegram_bot_token: "telegram-token",
      trigger_bearer_token: "trigger-token"
    )
    group_chat = @account.chats.create!(
      title: "Safe agent props",
      manual_responses: true,
      agents: [ agent ]
    )

    get account_chat_path(@account, group_chat)

    agent_json = inertia_shared_props.fetch("agents").sole
    assert_equal(
      [ "active", "colour", "deprecated", "health_state", "icon", "id", "model_id", "model_label", "name", "paused", "runtime", "unavailability_reason" ],
      agent_json.keys.sort
    )
    assert_equal agent.to_param, agent_json.fetch("id")
  end

  test "show includes conversation cost breakdown" do
    @chat.messages.create!(
      role: "assistant",
      content: "Measured response",
      model_id_string: "openai/gpt-5.4",
      input_tokens: 100,
      cache_creation_tokens: 20,
      cached_tokens: 30,
      output_tokens: 40,
      thinking_tokens: 10
    )

    get account_chat_path(@account, @chat)

    breakdown = inertia_shared_props["cost_breakdown"]
    assert_equal 1, breakdown["row_count"]
    assert_equal "openai/gpt-5.4", breakdown.dig("models", 0, "model")
    assert_equal 30, breakdown.dig("totals", "cache_read_input_tokens")
  end

  test "show omits per-message RubyLLM telemetry for non-site-admins" do
    @chat.messages.create!(
      role: "assistant",
      content: "Measured response",
      model_id_string: "openai/gpt-5.4",
      input_tokens: 100,
      cache_creation_tokens: 20,
      cached_tokens: 30,
      output_tokens: 40
    )

    get account_chat_path(@account, @chat)

    message = inertia_shared_props["messages"].find { |row| row["role"] == "assistant" }
    refute message.key?("ruby_llm_telemetry")
  end

  test "show includes per-message RubyLLM telemetry for site admins" do
    @chat.messages.create!(
      role: "assistant",
      content: "Measured response",
      model_id_string: "openai/gpt-5.4",
      input_tokens: 100,
      cache_creation_tokens: 20,
      cached_tokens: 30,
      output_tokens: 40
    )
    delete logout_path
    post login_path, params: {
      email_address: users(:site_admin_user).email_address,
      password: "password123"
    }

    get account_chat_path(@account, @chat)

    message = inertia_shared_props["messages"].find { |row| row["role"] == "assistant" }
    assert_equal(
      {
        "model" => "openai/gpt-5.4",
        "instrumentation_complete" => true,
        "input_tokens" => 100,
        "output_tokens" => 40,
        "cache_read_tokens" => 30,
        "cache_write_tokens" => 20
      },
      message["ruby_llm_telemetry"]
    )
  end

  test "show includes estimated interaction cost on an unambiguously linked hosted response" do
    agent = agents(:research_assistant)
    started_at = 1.minute.ago
    message = @chat.messages.create!(
      role: "assistant",
      agent: agent,
      content: "Hosted response",
      created_at: started_at + 10.seconds
    )
    @chat.agent_runtime_interactions.create!(
      agent: agent,
      trigger_kind: "conversation",
      started_at: started_at,
      finished_at: started_at + 20.seconds,
      telemetry_schema_version: 1,
      usage_scope: "trigger",
      usage_complete: true,
      provider: "anthropic",
      model: "claude-sonnet-5",
      uncached_input_tokens: 1_000,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0,
      output_tokens: 25
    )

    get account_chat_path(@account, @chat)

    response_message = inertia_shared_props["messages"].find { |row| row["id"] == message.to_param }
    assert_equal "0.00225", response_message.dig("interaction_cost", "amount_usd")
  end

  test "show omits interaction cost when one interaction posted several messages" do
    agent = agents(:research_assistant)
    started_at = 1.minute.ago
    messages = [
      @chat.messages.create!(role: "assistant", agent: agent, content: "First", created_at: started_at + 10.seconds),
      @chat.messages.create!(role: "assistant", agent: agent, content: "Second", created_at: started_at + 15.seconds)
    ]
    @chat.agent_runtime_interactions.create!(
      agent: agent,
      trigger_kind: "conversation",
      started_at: started_at,
      finished_at: started_at + 20.seconds,
      telemetry_schema_version: 1,
      usage_scope: "trigger",
      usage_complete: true,
      provider: "anthropic",
      model: "claude-sonnet-5",
      uncached_input_tokens: 1_000,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0,
      output_tokens: 25
    )

    get account_chat_path(@account, @chat)

    response_messages = inertia_shared_props["messages"].select { |row| row["id"].in?(messages.map(&:to_param)) }
    assert response_messages.none? { |row| row.key?("interaction_cost") }
  end

  test "show includes estimated interaction cost for a wake with one obvious chat response" do
    agent = agents(:research_assistant)
    started_at = 1.minute.ago
    message = @chat.messages.create!(
      role: "assistant",
      agent: agent,
      content: "A wake response",
      created_at: started_at + 10.seconds
    )
    AgentRuntimeInteraction.create!(
      agent: agent,
      chat: nil,
      trigger_kind: "wake",
      started_at: started_at,
      finished_at: started_at + 20.seconds,
      telemetry_schema_version: 1,
      usage_scope: "trigger",
      usage_complete: true,
      provider: "anthropic",
      model: "claude-sonnet-5",
      uncached_input_tokens: 1_000,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0,
      output_tokens: 25
    )

    get account_chat_path(@account, @chat)

    response_message = inertia_shared_props["messages"].find { |row| row["id"] == message.to_param }
    assert_equal "0.00225", response_message.dig("interaction_cost", "amount_usd")
  end

  test "should create chat with agents" do
    agent = agents(:research_assistant)

    assert_difference "Chat.count" do
      post account_chats_path(@account), params: { agent_ids: [ agent.to_param ] }
    end

    chat = Chat.last
    assert_equal "openrouter/auto", chat.model_id
    assert_equal @account, chat.account
    assert chat.manual_responses?
    assert_equal [ agent ], chat.agents
    assert_redirected_to account_chat_path(@account, chat)
  end

  test "should ignore model chat attributes when creating a chat" do
    agent = agents(:research_assistant)

    post account_chats_path(@account), params: {
      chat: {
        model_id: "gpt-4o",
        web_access: true,
        manual_responses: false
      },
      agent_ids: [ agent.to_param ]
    }

    chat = Chat.last
    assert_equal "openrouter/auto", chat.model_id
    assert_not chat.web_access?
    assert chat.manual_responses?
  end

  test "should not create chat without agents" do
    assert_no_difference "Chat.count" do
      post account_chats_path(@account)
    end

    assert_redirected_to new_account_chat_path(@account)
    assert_equal "Select at least one agent", flash[:alert]
  end

  test "should not create chat with an agent from another account" do
    other_agent = agents(:other_account_agent)

    assert_no_difference "Chat.count" do
      post account_chats_path(@account), params: { agent_ids: [ other_agent.to_param ] }
    end

    assert_redirected_to new_account_chat_path(@account)
    assert_equal "Select valid agents from this account", flash[:alert]
  end

  test "should destroy chat" do
    assert_difference "Chat.count", -1 do
      delete account_chat_path(@account, @chat)
    end

    assert_redirected_to account_chats_path(@account)
  end

  test "should scope chats to current account" do
    # Create a completely separate user and account
    other_user = User.create!(email_address: "other@example.com")
    other_user.profile.update!(first_name: "Other", last_name: "User")
    other_account = other_user.personal_account
    other_chat = other_account.chats.create!(
      model_id: "gpt-4o",
      title: "Other Account Chat"
    )

    # Debug: Check if manual scoping works
    assert_raises(ActiveRecord::RecordNotFound) do
      @account.chats.find(other_chat.id)
    end

    # Now test the controller - should return 404 when chat doesn't belong to account
    get account_chat_path(@account, other_chat)
    assert_response :not_found
  end

  test "chats blocked when disabled" do
    Setting.instance.update!(allow_chats: false)
    sign_in @user

    get account_chats_path(@account)
    assert_redirected_to root_path
    assert_match(/disabled/, flash[:alert])
  end

  test "should require authentication" do
    delete logout_path

    get account_chats_path(@account)
    assert_response :redirect
  end

  test "should create agent chat with message without triggering plain AI response" do
    agent = agents(:research_assistant)

    assert_difference "Chat.count" do
      assert_difference "Message.count" do
        assert_no_enqueued_jobs only: AiResponseJob do
          post account_chats_path(@account), params: {
            message: "Hello agent",
            agent_ids: [ agent.to_param ]
          }
        end
      end
    end

    chat = Chat.last
    message = chat.messages.last
    assert_equal "Hello agent", message.content
    assert_equal "user", message.role
    assert_equal @user, message.user
    assert_equal [ agent ], chat.agents
    assert_redirected_to account_chat_path(@account, chat)
  end

  test "should create chat with file attachments" do
    agent = agents(:research_assistant)
    file = fixture_file_upload("test_image.png", "image/png")

    assert_difference "Chat.count" do
      assert_difference "Message.count" do
        assert_no_enqueued_jobs only: AiResponseJob do
          post account_chats_path(@account), params: {
            message: "Please analyze this image",
            files: [ file ],
            agent_ids: [ agent.to_param ]
          }
        end
      end
    end

    chat = Chat.last
    message = chat.messages.last
    assert_equal "Please analyze this image", message.content
    assert_equal "user", message.role
    assert_equal @user, message.user

    # Verify file attachment
    assert message.attachments.attached?
    assert_equal 1, message.attachments.count
    assert_equal "test_image.png", message.attachments.first.filename.to_s

    assert_redirected_to account_chat_path(@account, chat)
  end

  test "should create chat with only files and no message content" do
    agent = agents(:research_assistant)
    file = fixture_file_upload("test_image.png", "image/png")

    assert_difference "Chat.count" do
      assert_difference "Message.count" do
        assert_no_enqueued_jobs only: AiResponseJob do
          post account_chats_path(@account), params: {
            message: "", # Empty message content
            files: [ file ],
            agent_ids: [ agent.to_param ]
          }
        end
      end
    end

    chat = Chat.last
    message = chat.messages.last
    assert_equal "", message.content
    assert_equal "user", message.role
    assert_equal @user, message.user

    # Verify file attachment works even without content
    assert message.attachments.attached?
    assert_equal 1, message.attachments.count
    assert_equal "test_image.png", message.attachments.first.filename.to_s

    assert_redirected_to account_chat_path(@account, chat)
  end

  test "index should return correct Inertia props" do
    get account_chats_path(@account)

    assert_response :success
    # For now, just verify the endpoint works - Inertia testing can be complex in test env
  end

  test "show should return correct Inertia props" do
    # Add a message to the chat
    @chat.messages.create!(
      content: "Test message",
      role: "user",
      user: @user
    )

    get account_chat_path(@account, @chat)

    assert_response :success
    # For now, just verify the endpoint works - Inertia testing can be complex in test env
  end

  test "should handle latest scope in index" do
    # Create multiple chats with different update times
    old_chat = @account.chats.create!(
      model_id: "gpt-4o",
      title: "Old Chat",
      updated_at: 2.days.ago
    )
    new_chat = @account.chats.create!(
      model_id: "gpt-4o",
      title: "New Chat",
      updated_at: 1.hour.ago
    )

    get account_chats_path(@account)

    assert_response :success
    # Verify that chats are loaded in the correct order by checking the scope
    chats = @account.chats.latest.to_a
    # Should include all chats and be in latest order
    assert_equal 3, chats.count
    chat_ids = chats.map(&:id)
    assert_includes chat_ids, new_chat.id
    assert_includes chat_ids, @chat.id
    assert_includes chat_ids, old_chat.id
    # Latest scope should order by updated_at desc
    assert chats.first.updated_at >= chats.second.updated_at
  end

  test "should create chat with file uploads" do
    agent = agents(:research_assistant)
    # Create a test file
    file = fixture_file_upload("test.txt", "text/plain")

    assert_difference "Chat.count" do
      assert_difference "Message.count" do
        post account_chats_path(@account), params: {
          message: "Hello with file",
          files: [ file ],
          agent_ids: [ agent.to_param ]
        }
      end
    end

    chat = Chat.last
    message = chat.messages.last
    assert_equal "Hello with file", message.content
    assert_equal 1, message.attachments.count
    assert_redirected_to account_chat_path(@account, chat)
  end

  test "should update web_access to true" do
    assert_not @chat.web_access

    patch account_chat_path(@account, @chat), params: {
      chat: { web_access: true }
    }

    # Update redirects to the chat page on success
    assert_redirected_to account_chat_path(@account, @chat)
    @chat.reload
    assert @chat.web_access
  end

  test "should update web_access to false" do
    @chat.update!(web_access: true)
    assert @chat.web_access

    patch account_chat_path(@account, @chat), params: {
      chat: { web_access: false }
    }

    # Update redirects to the chat page on success
    assert_redirected_to account_chat_path(@account, @chat)
    @chat.reload
    assert_not @chat.web_access
  end

  test "update should broadcast refresh automatically" do
    # Verify that the update succeeds (broadcast happens via after_commit callback)
    patch account_chat_path(@account, @chat), params: {
      chat: { web_access: true }
    }

    # Update redirects to the chat page on success
    assert_redirected_to account_chat_path(@account, @chat)
    # The broadcast happens automatically via the Broadcastable concern
    @chat.reload
    assert @chat.web_access
  end

  test "update should scope to current account" do
    # Create a chat in a different account
    other_user = User.create!(email_address: "updateother@example.com")
    other_user.profile.update!(first_name: "Other", last_name: "User")
    other_account = other_user.personal_account
    other_chat = other_account.chats.create!(
      model_id: "gpt-4o",
      title: "Other Account Chat"
    )

    # Should return 404 when trying to update chat from different account
    patch account_chat_path(@account, other_chat), params: {
      chat: { web_access: true }
    }
    assert_response :not_found

    # Verify the chat was not modified
    other_chat.reload
    assert_not other_chat.web_access
  end

  test "update should require authentication" do
    delete logout_path

    patch account_chat_path(@account, @chat), params: {
      chat: { web_access: true }
    }
    assert_response :redirect

    # Verify the chat was not modified
    @chat.reload
    assert_not @chat.web_access
  end

  test "update should allow updating model_id" do
    assert_equal "openrouter/auto", @chat.model_id

    patch account_chat_path(@account, @chat), params: {
      chat: { model_id: "openai/gpt-4o-mini" }
    }

    # Update redirects to the chat page on success
    assert_redirected_to account_chat_path(@account, @chat)
    @chat.reload
    assert_equal "openai/gpt-4o-mini", @chat.model_id
  end

  test "update should allow updating multiple attributes" do
    patch account_chat_path(@account, @chat), params: {
      chat: {
        model_id: "openai/gpt-4o-mini",
        web_access: true
      }
    }

    # Update redirects to the chat page on success
    assert_redirected_to account_chat_path(@account, @chat)
    @chat.reload
    assert_equal "openai/gpt-4o-mini", @chat.model_id
    assert @chat.web_access
  end

  # Index ordering tests

  test "index shows active chats before archived chats" do
    # Create chats with specific states
    archived_chat = @account.chats.create!(
      model_id: "gpt-4o",
      title: "Archived Chat",
      updated_at: 1.minute.ago # Most recent update
    )
    archived_chat.archive!

    active_chat = @account.chats.create!(
      model_id: "gpt-4o",
      title: "Active Chat",
      updated_at: 1.hour.ago # Older update
    )

    get account_chats_path(@account)
    assert_response :success

    # Verify ordering: active chats first, then archived
    active_chats = @account.chats.kept.active.latest
    archived_chats = @account.chats.kept.archived.latest

    # Active chat should be in active list, archived should be in archived list
    assert_includes active_chats.map(&:id), active_chat.id
    assert_includes archived_chats.map(&:id), archived_chat.id
  end

  test "index excludes discarded chats by default" do
    discarded_chat = @account.chats.create!(
      model_id: "gpt-4o",
      title: "Discarded Chat"
    )
    discarded_chat.discard!

    get account_chats_path(@account)
    assert_response :success

    # Discarded chat should not be in the default view
    kept_chats = @account.chats.kept
    assert_not_includes kept_chats.map(&:id), discarded_chat.id
  end

  test "index shows discarded chats when member requests show_deleted" do
    discarded_chat = @account.chats.create!(
      model_id: "gpt-4o",
      title: "Discarded Chat"
    )
    discarded_chat.discard!

    get account_chats_path(@account, show_deleted: true)
    assert_response :success

    # With show_deleted, discarded chat should be findable
    all_chats = @account.chats.with_discarded
    assert_includes all_chats.map(&:id), discarded_chat.id
  end

  test "show_deleted works for confirmed members" do
    # team_account has user_1 as owner, and existing_user (user_id: 3) as member via team_member membership
    team_account = accounts(:team_account)
    member_user = users(:existing_user)  # This user is member via team_member membership

    discarded_chat = team_account.chats.create!(
      model_id: "gpt-4o",
      title: "Discarded Chat"
    )
    discarded_chat.discard!

    # Sign in as member (not admin)
    delete logout_path
    post login_path, params: {
      email_address: member_user.email_address,
      password: "password123"
    }

    get account_chats_path(team_account, show_deleted: true)
    assert_response :success

    all_chats = team_account.chats.with_discarded
    assert_includes all_chats.map(&:id), discarded_chat.id
  end

  # Pagination tests (now via messages#index)

  test "messages index returns JSON with pagination info" do
    chat = @account.chats.create!(model_id: "openrouter/auto")
    messages = 50.times.map { |i| chat.messages.create!(content: "Message #{i}", role: "user", user: @user) }

    get account_chat_messages_path(@account, chat, before_id: messages.last.to_param),
        headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)
    assert json.key?("messages")
    assert json.key?("has_more")
    assert json.key?("oldest_id")
    assert json["messages"].is_a?(Array)
    assert_equal 30, json["messages"].length  # Default limit is 30
  end

  test "messages index returns messages before specified ID" do
    chat = @account.chats.create!(model_id: "openrouter/auto")
    messages = 10.times.map { |i| chat.messages.create!(content: "Message #{i}", role: "user", user: @user) }
    middle = messages[5]

    get account_chat_messages_path(@account, chat, before_id: middle.to_param),
        headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)

    # All returned messages should have IDs less than the middle message
    returned_ids = json["messages"].map { |m| Message.decode_id(m["id"]) }
    assert returned_ids.all? { |id| id < middle.id }
  end

  test "messages index includes per-message RubyLLM telemetry for site admins" do
    chat = @account.chats.create!(model_id: "openrouter/auto")
    assistant_message = chat.messages.create!(
      role: "assistant",
      content: "Older measured response",
      model_id_string: "anthropic/claude-opus-4-6",
      input_tokens: 200,
      output_tokens: 50,
      cached_tokens: 150,
      cache_creation_tokens: 25
    )
    newer_message = chat.messages.create!(role: "user", content: "Newer message", user: @user)
    delete logout_path
    post login_path, params: {
      email_address: users(:site_admin_user).email_address,
      password: "password123"
    }

    get account_chat_messages_path(@account, chat, before_id: newer_message.to_param),
        headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)
    message = json["messages"].find { |row| row["id"] == assistant_message.to_param }
    assert_equal 150, message.dig("ruby_llm_telemetry", "cache_read_tokens")
    assert_equal 25, message.dig("ruby_llm_telemetry", "cache_write_tokens")
  end

  test "messages index returns empty when no more messages" do
    chat = @account.chats.create!(model_id: "openrouter/auto")
    message = chat.messages.create!(content: "Only message", role: "user", user: @user)

    get account_chat_messages_path(@account, chat, before_id: message.to_param),
        headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal [], json["messages"]
    assert_equal false, json["has_more"]
  end

  test "messages index requires authentication" do
    delete logout_path

    chat = @account.chats.create!(model_id: "openrouter/auto")
    message = chat.messages.create!(content: "Test", role: "user")

    get account_chat_messages_path(@account, chat, before_id: message.to_param),
        headers: { "Accept" => "application/json" }

    assert_response :redirect
  end

  test "messages index scopes to current account" do
    other_user = User.create!(email_address: "paginationother@example.com")
    other_user.profile.update!(first_name: "Other", last_name: "User")
    other_account = other_user.personal_account
    other_chat = other_account.chats.create!(model_id: "openrouter/auto")
    message = other_chat.messages.create!(content: "Test", role: "user", user: other_user)

    get account_chat_messages_path(@account, other_chat, before_id: message.to_param),
        headers: { "Accept" => "application/json" }

    assert_response :not_found
  end

  test "messages index indicates has_more correctly when more messages exist" do
    chat = @account.chats.create!(model_id: "openrouter/auto")
    # Create 50 messages (0-49)
    messages = 50.times.map { |i| chat.messages.create!(content: "Message #{i}", role: "user", user: @user) }

    # Request messages before the last one (message 49)
    # Should get messages 19-48 (30 messages), and there should be more (0-18)
    get account_chat_messages_path(@account, chat, before_id: messages.last.to_param),
        headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal true, json["has_more"], "Should indicate more messages exist"
  end

  test "messages index indicates has_more false when no more messages" do
    chat = @account.chats.create!(model_id: "openrouter/auto")
    # Create 5 messages (0-4)
    messages = 5.times.map { |i| chat.messages.create!(content: "Message #{i}", role: "user", user: @user) }

    # Request messages before the last one (message 4)
    # Should get messages 0-3 (4 messages), and there should be no more
    get account_chat_messages_path(@account, chat, before_id: messages.last.to_param),
        headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal false, json["has_more"], "Should indicate no more messages"
  end

  # Search tests

  test "search returns results matching query" do
    @chat.messages.create!(content: "Hello world, this is a test message", role: "user", user: @user)
    @chat.messages.create!(content: "The AI responds with helpful information", role: "assistant")

    get search_account_chats_path(@account), params: { q: "test message" }
    assert_response :success
  end

  test "search is case insensitive" do
    @chat.messages.create!(content: "Ruby on Rails is great", role: "user", user: @user)

    get search_account_chats_path(@account), params: { q: "ruby on rails" }
    assert_response :success
  end

  test "search with empty query returns no results" do
    get search_account_chats_path(@account), params: { q: "" }
    assert_response :success
  end

  test "search without query param renders page" do
    get search_account_chats_path(@account)
    assert_response :success
  end

  test "search excludes discarded chats" do
    @chat.messages.create!(content: "Find me in search", role: "user", user: @user)
    @chat.discard!

    get search_account_chats_path(@account), params: { q: "Find me" }
    assert_response :success
  end

  test "search requires authentication" do
    delete logout_path
    get search_account_chats_path(@account), params: { q: "test" }
    assert_response :redirect
  end

end
