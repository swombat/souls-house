require "test_helper"
require "support/app_oauth_test_helper"

# Issue #94 B, step 4b-iii: conversation create (retry-safe by client
# identity, like a send), invoke, and activity through /api/app/v1.
class Api::App::V1::ConversationApiTest < ActionDispatch::IntegrationTest

  include AppOauthTestHelper
  include ActiveJob::TestHelper

  setup do
    @user = users(:existing_user)
    @account = accounts(:existing_user_account)
    @client = create_app_client
    @tokens = sign_in_device
    @agent = @account.agents.create!(name: "Grok", system_prompt: "Test", runtime: "external")
    @other = @account.agents.create!(name: "Ada", system_prompt: "Test", runtime: "external")
  end

  # --- create ----------------------------------------------------------------

  test "create is 201 with an empty conversation of the named residents, and is audited" do
    assert_difference -> { @account.chats.count }, 1 do
      assert_no_difference -> { Message.count } do
        create_conversation("conv-00000001", [ @agent, @other ], title: "From the phone")
      end
    end
    assert_response :created
    body = response.parsed_body["conversation"]
    chat = @account.chats.find(body["id"])
    assert chat.manual_responses
    assert_equal [ @agent, @other ].map(&:id).sort, chat.agent_ids.sort
    assert_equal [ "From the phone", 0 ], body.values_at("title", "latest_revision")
    assert_equal [ @agent, @other ].map(&:to_param).sort, body["participants"].pluck("id").sort
    audit = AuditLog.find_by!(action: "create_chat", auditable: chat)
    assert_equal [ @account, "conv-00000001" ], [ audit.account, audit.data["client_conversation_id"] ]
    assert audit.data["app_session_id"].present?
  end

  test "an identical retry is 200 with the same conversation and creates nothing" do
    create_conversation("conv-00000001", [ @agent, @other ], title: "Hi")
    first = response.parsed_body["conversation"]

    assert_no_difference -> { Chat.count } do
      create_conversation("conv-00000001", [ @other, @agent ], title: "Hi")
    end
    assert_response :ok
    assert_equal first["id"], response.parsed_body.dig("conversation", "id")
  end

  test "a retry still finds its conversation after it is renamed; a different payload is 409" do
    create_conversation("conv-00000001", [ @agent ])
    id = response.parsed_body.dig("conversation", "id")
    @account.chats.find(id).update!(title: "Renamed later")

    create_conversation("conv-00000001", [ @agent ])
    assert_response :ok
    assert_equal id, response.parsed_body.dig("conversation", "id")

    assert_no_difference -> { Chat.count } do
      create_conversation("conv-00000001", [ @agent, @other ])
    end
    assert_error :conflict, "idempotency_conflict"
    assert_equal id, response.parsed_body.dig("error", "details", "conversation_id")
  end

  test "a retry still finds its conversation after a resident is deactivated or reprovisioned" do
    create_conversation("conv-00000001", [ @agent, @other ], title: "Hi")
    id = response.parsed_body.dig("conversation", "id")
    @agent.update!(active: false)
    @other.update!(runtime: "provisioning")

    assert_no_difference -> { Chat.count } do
      create_conversation("conv-00000001", [ @other, @agent ], title: "Hi")
    end
    assert_response :ok
    assert_equal id, response.parsed_body.dig("conversation", "id")

    # A different payload under the same identity is still a conflict, and a
    # new identity still checks who can join a new conversation today.
    create_conversation("conv-00000001", [ @agent ], title: "Hi")
    assert_error :conflict, "idempotency_conflict"
    assert_no_difference -> { Chat.count } do
      create_conversation("conv-00000002", [ @agent, @other ], title: "Hi")
    end
    assert_error :unprocessable_entity, "invalid_parameter"
  end

  test "a retry of a conversation deleted since is 404 and does not recreate it" do
    create_conversation("conv-00000001", [ @agent ])
    @account.chats.find(response.parsed_body.dig("conversation", "id")).discard!

    assert_no_difference -> { Chat.count } do
      create_conversation("conv-00000001", [ @agent ])
    end
    assert_error :not_found, "not_found"
  end

  test "create refuses a malformed identity and residents it may not use" do
    create_conversation("short", [ @agent ])
    assert_error :unprocessable_entity, "invalid_parameter"

    create_conversation("conv-00000001", [])
    assert_error :unprocessable_entity, "invalid_parameter"

    elsewhere = accounts(:team_account).agents.create!(name: "Elsewhere", system_prompt: "Test", runtime: "external")
    assert_no_difference -> { Chat.count } do
      create_conversation("conv-00000001", [ @agent, elsewhere ])
      create_conversation("conv-00000002", [ @agent ], extra: { agent_ids: [ @agent.to_param, "not-an-id!" ] })
    end
    assert_error :unprocessable_entity, "invalid_parameter"
    assert_equal "agent_ids", response.parsed_body.dig("error", "details", "parameter")
  end

  test "create in an account the user is not a confirmed member of is 404" do
    outside = Account.create!(name: "Not mine", account_type: "team")
    agent = outside.agents.create!(name: "Theirs", system_prompt: "Test", runtime: "external")
    assert_no_difference -> { Chat.count } do
      post "/api/app/v1/accounts/#{outside.to_param}/conversations",
           params: { client_conversation_id: "conv-00000001", agent_ids: [ agent.to_param ] }, headers: bearer(@tokens)
    end
    assert_error :not_found, "not_found"
  end

  # --- invoke ----------------------------------------------------------------

  test "invoke of one resident is 202 and reserves its run" do
    chat = conversation_with(@agent, @other)
    assert_difference -> { chat.agent_runtime_interactions.count }, 1 do
      assert_enqueued_jobs 1, only: ManualAgentResponseJob do
        post "/api/app/v1/conversations/#{chat.to_param}/invoke", params: { agent_id: @agent.to_param }, headers: bearer(@tokens)
      end
    end
    assert_response :accepted
    assert_equal @agent, chat.agent_runtime_interactions.last.agent
  end

  test "invoke of everyone is 202 and queues the round" do
    chat = conversation_with(@agent, @other)
    assert_enqueued_with(job: AllAgentsResponseJob) do
      post "/api/app/v1/conversations/#{chat.to_param}/invoke", headers: bearer(@tokens)
    end
    assert_response :accepted
  end

  test "invoke while a resident is already responding is 409 and queues nothing" do
    chat = conversation_with(@agent, @other)
    chat.agent_runtime_interactions.create!(agent: @agent, trigger_kind: "conversation", started_at: 1.minute.ago)

    assert_no_enqueued_jobs do
      post "/api/app/v1/conversations/#{chat.to_param}/invoke", params: { agent_id: @agent.to_param }, headers: bearer(@tokens)
      assert_error :conflict, "already_responding"
      post "/api/app/v1/conversations/#{chat.to_param}/invoke", headers: bearer(@tokens)
      assert_error :conflict, "already_responding"
    end
  end

  # The lock inside reserve! is where a concurrent invoke loses; it must be
  # told apart the same way as the pre-check, or the loser would see 422.
  test "a reservation lost to a concurrent run raises AlreadyResponding" do
    chat = conversation_with(@agent)
    AgentRuntimeInteraction.reserve!(agent: @agent, chat: chat, enqueue: false)
    assert_raises(Chat::AlreadyResponding) { AgentRuntimeInteraction.reserve!(agent: @agent, chat: chat, enqueue: false) }
  end

  test "invoke of an archived conversation is 422; of a resident outside it, 404" do
    chat = conversation_with(@agent)
    post "/api/app/v1/conversations/#{chat.to_param}/invoke", params: { agent_id: @other.to_param }, headers: bearer(@tokens)
    assert_error :not_found, "not_found"

    chat.archive!
    assert_no_enqueued_jobs do
      post "/api/app/v1/conversations/#{chat.to_param}/invoke", headers: bearer(@tokens)
    end
    assert_error :unprocessable_entity, "not_invokable"
  end

  # --- activity --------------------------------------------------------------

  test "activity lists recent runs as status only, never diagnostics or narration" do
    chat = conversation_with(@agent)
    chat.agent_runtime_interactions.create!(
      agent: @agent, trigger_kind: "conversation", started_at: 1.minute.ago,
      stdout: "PRIVATE-CANARY", stderr: "PRIVATE-CANARY"
    )
    get "/api/app/v1/conversations/#{chat.to_param}/activity", headers: bearer(@tokens)
    assert_response :ok
    rows = response.parsed_body["activity"]
    assert_equal 1, rows.size
    assert_equal [ @agent.to_param, "running", true ], [ rows[0].dig("agent", "id"), rows[0]["status"], rows[0]["active"] ]
    assert_equal %w[active agent conversation_id created_at finished_at id started_at status trigger_kind], rows[0].keys.sort
    assert_not_includes response.body, "PRIVATE-CANARY"
  end

  test "activity shows a reserved live run with its live status" do
    chat = conversation_with(@agent)
    run = AgentRuntimeInteraction.reserve!(agent: @agent, chat: chat, enqueue: false)

    get "/api/app/v1/conversations/#{chat.to_param}/activity", headers: bearer(@tokens)
    assert_response :ok
    row = response.parsed_body["activity"].sole
    assert_equal [ run.to_param, "queued", true ], row.values_at("id", "status", "active")
  end

  test "activity and invoke of a conversation in another account are 404" do
    outside = Account.create!(name: "Not mine", account_type: "team")
    agent = outside.agents.create!(name: "Theirs", system_prompt: "Test", runtime: "external")
    chat = outside.chats.new(model_id: "openrouter/auto", manual_responses: true)
    chat.agent_ids = [ agent.id ]
    chat.save!

    get "/api/app/v1/conversations/#{chat.to_param}/activity", headers: bearer(@tokens)
    assert_error :not_found, "not_found"
    assert_no_enqueued_jobs do
      post "/api/app/v1/conversations/#{chat.to_param}/invoke", headers: bearer(@tokens)
    end
    assert_error :not_found, "not_found"
  end

  private

  def create_conversation(client_conversation_id, agents, title: nil, extra: {})
    params = { client_conversation_id: client_conversation_id, agent_ids: agents.map(&:to_param) }
    params[:title] = title if title
    post "/api/app/v1/accounts/#{@account.to_param}/conversations", params: params.merge(extra), headers: bearer(@tokens)
  end

  def conversation_with(*agents)
    chat = @account.chats.new(model_id: "openrouter/auto", title: "Phone chat", manual_responses: true)
    chat.agent_ids = agents.map(&:id)
    chat.save!
    chat
  end

  def assert_error(status, code)
    assert_response status
    assert_equal code, response.parsed_body.dig("error", "code")
    assert response.parsed_body.dig("error", "request_id").present?
  end

end
