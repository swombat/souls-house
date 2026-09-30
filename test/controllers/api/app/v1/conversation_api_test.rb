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

  # --- invoke (keyed: #94 B, keyed-invoke extension) -------------------------

  test "invoke of one resident is 202, records a keyed invocation and reserves its run" do
    chat = conversation_with(@agent, @other)
    assert_difference -> { chat.agent_runtime_interactions.count }, 1 do
      assert_enqueued_jobs 1, only: ManualAgentResponseJob do
        invoke(chat, "invoke-00000001", @agent)
      end
    end
    assert_response :accepted
    dispatch = MessageDispatch.find_by!(chat: chat, client_invocation_id: "invoke-00000001")
    assert_equal [ "invoke", "reserved", nil, [ @agent.id ] ], [ dispatch.kind, dispatch.status, dispatch.message_id, dispatch.target_agent_ids ]
    run = dispatch.runtime_interaction
    assert_equal [ @agent, dispatch ], [ run.agent, run.message_dispatch ]
    assert_operator run.execution_deadline_at, :<=, dispatch.expires_at
    body = response.parsed_body["invocation"]
    assert_equal [ "invoke", "invoke-00000001", "reserved" ], body.values_at("kind", "client_invocation_id", "status")
    assert_equal [ run.run_id ], body["runs"].pluck("run_id")
  end

  test "invoke of everyone reserves the first resident with the rest as its chain, not an unkeyed job" do
    chat = conversation_with(@agent, @other)
    assert_no_enqueued_jobs only: AllAgentsResponseJob do
      invoke(chat, "invoke-00000001")
    end
    assert_response :accepted
    dispatch = MessageDispatch.find_by!(client_invocation_id: "invoke-00000001")
    ordered = [ @agent, @other ].map(&:id).sort
    assert_equal ordered, dispatch.target_agent_ids
    assert_equal [ ordered.first, ordered.drop(1) ], [ dispatch.runtime_interaction.agent_id, dispatch.runtime_interaction.response_chain_agent_ids ]
  end

  test "invoke without a valid client_invocation_id is 422 and starts nothing" do
    chat = conversation_with(@agent)
    [ nil, "short", "has spaces in it" ].each do |key|
      assert_no_difference -> { MessageDispatch.count } do
        post "/api/app/v1/conversations/#{chat.to_param}/invoke", params: { client_invocation_id: key }.compact, headers: bearer(@tokens)
      end
      assert_error :unprocessable_entity, "invalid_parameter"
    end
  end

  test "the same key returns its own invocation while running and after it finishes, and never starts another run" do
    chat = conversation_with(@agent)
    invoke(chat, "invoke-00000001", @agent)
    run = MessageDispatch.find_by!(client_invocation_id: "invoke-00000001").runtime_interaction
    run.claim_dispatch!

    assert_no_difference -> { AgentRuntimeInteraction.count } do
      assert_no_enqueued_jobs only: ManualAgentResponseJob do
        invoke(chat, "invoke-00000001", @agent)
        assert_response :accepted
        assert_equal [ [ run.run_id, "preparing" ] ], response.parsed_body.dig("invocation", "runs").map { |r| r.values_at("run_id", "status") }

        run.reload.finish_execution!("completed")
        invoke(chat, "invoke-00000001", @agent)
        assert_response :accepted
        assert_equal [ "completed" ], response.parsed_body.dig("invocation", "runs").pluck("status")
      end
    end
  end

  test "the same key with a different request is 409" do
    chat = conversation_with(@agent, @other)
    invoke(chat, "invoke-00000001", @agent)
    assert_no_difference -> { AgentRuntimeInteraction.count } do
      invoke(chat, "invoke-00000001", @other)
      assert_error :conflict, "idempotency_conflict"
      invoke(chat, "invoke-00000001")
      assert_error :conflict, "idempotency_conflict"
    end
  end

  # A retry is judged against what was asked, before anything a new
  # invocation would need; only account access is re-checked.
  test "a retry is answered from its record after the resident leaves, is deactivated, or live activity goes off" do
    chat = conversation_with(@agent, @other)
    invoke(chat, "invoke-00000001", @agent)
    MessageDispatch.find_by!(client_invocation_id: "invoke-00000001").runtime_interaction.finish_execution!("completed")
    invoke(chat, "invoke-00000002")
    assert_response :accepted
    chat.agent_ids = [ @other.id ]
    @agent.update!(active: false)
    ENV["SOULSHOUSE_LIVE_ACTIVITY"] = "0"

    assert_no_difference -> { AgentRuntimeInteraction.count } do
      invoke(chat, "invoke-00000001", @agent)
      assert_response :accepted
      invoke(chat, "invoke-00000002")
      assert_response :accepted
    end
    assert_equal [ @agent.id, @other.id ].sort, MessageDispatch.find_by!(client_invocation_id: "invoke-00000002").target_agent_ids
  ensure
    ENV.delete("SOULSHOUSE_LIVE_ACTIVITY")
  end

  test "a new invocation while live activity is off is 503 and writes nothing" do
    chat = conversation_with(@agent)
    ENV["SOULSHOUSE_LIVE_ACTIVITY"] = "0"
    assert_no_difference [ "MessageDispatch.count", "AgentRuntimeInteraction.count" ] do
      assert_no_enqueued_jobs do
        invoke(chat, "invoke-00000001", @agent)
        assert_error :service_unavailable, "live_activity_unavailable"
        assert response.parsed_body.dig("error", "details", "retryable")
        invoke(chat, "invoke-00000002")
        assert_error :service_unavailable, "live_activity_unavailable"
      end
    end
  ensure
    ENV.delete("SOULSHOUSE_LIVE_ACTIVITY")
  end

  test "invoke while a resident is already responding is 409, for one or all, and writes nothing" do
    chat = conversation_with(@agent, @other)
    chat.agent_runtime_interactions.create!(agent: @other, trigger_kind: "conversation", started_at: 1.minute.ago)

    assert_no_difference -> { MessageDispatch.count } do
      assert_no_enqueued_jobs do
        invoke(chat, "invoke-00000001", @other)
        assert_error :conflict, "already_responding"
        invoke(chat, "invoke-00000002")
        assert_error :conflict, "already_responding"
      end
    end
  end

  # Busy for everyone is decided under the chat lock with the reservation,
  # not before it: a run that appears after the controller's checks still
  # refuses the whole invocation.
  test "a run that starts between the checks and the reservation refuses invoke-all with nothing written" do
    chat = conversation_with(@agent, @other)
    later = [ @agent, @other ].max_by(&:id)
    original = chat.class.instance_method(:respondable?)
    raced = false
    Chat.define_method(:respondable?) do
      result = original.bind_call(self)
      unless raced
        raced = true
        agent_runtime_interactions.create!(agent: later, trigger_kind: "conversation", started_at: Time.current)
      end
      result
    end
    assert_no_difference -> { MessageDispatch.count } do
      invoke(chat, "invoke-00000001")
    end
    assert_error :conflict, "already_responding"
  ensure
    Chat.define_method(:respondable?, original)
  end

  test "invoke of a resident outside the conversation is 404; of an archived one, 422; of one who can't run, 409 with why" do
    chat = conversation_with(@agent)
    invoke(chat, "invoke-00000001", @other)
    assert_error :not_found, "not_found"
    post "/api/app/v1/conversations/#{chat.to_param}/invoke", params: { client_invocation_id: "invoke-00000002", agent_id: "not-a-hashid" }, headers: bearer(@tokens)
    assert_error :not_found, "not_found"

    @agent.update!(active: false)
    invoke(chat, "invoke-00000003", @agent)
    assert_error :conflict, "agent_inactive"
    invoke(chat, "invoke-00000004")
    assert_error :conflict, "no_available_agents"
    @agent.update!(active: true)

    chat.archive!
    assert_no_difference -> { MessageDispatch.count } do
      invoke(chat, "invoke-00000005")
    end
    assert_error :unprocessable_entity, "not_invokable"
  end

  test "a runtime enqueue that fails after commit still answers 202; the run is not re-driven and lapses at its deadline" do
    chat = conversation_with(@agent)
    ManualAgentResponseJob.stub(:perform_later, ->(*) { raise "queue unavailable" }) do
      invoke(chat, "invoke-00000001", @agent)
    end
    assert_response :accepted
    dispatch = MessageDispatch.find_by!(client_invocation_id: "invoke-00000001")
    run = dispatch.runtime_interaction
    assert_equal "reserved", dispatch.status

    travel 31.seconds do
      assert_no_enqueued_jobs { MessageDispatchSweepJob.perform_now }
    end
    travel MessageDispatch::EXPIRY + 1.minute do
      MessageDispatchSweepJob.perform_now
      assert_equal "cancelled", run.reload.execution_state
      assert_not run.claim_dispatch!
      # Asking again, explicitly, starts one fresh run.
      assert_enqueued_jobs(1, only: ManualAgentResponseJob) { invoke(chat, "invoke-00000002", @agent) }
      assert_response :accepted
    end
  end

  test "an invocation from someone who has lost membership is cancelled at its claim" do
    chat = conversation_with(@agent)
    invoke(chat, "invoke-00000001", @agent)
    dispatch = MessageDispatch.find_by!(client_invocation_id: "invoke-00000001")
    Membership.where(user: @user, account: @account).update_all(confirmed_at: nil)

    assert_not dispatch.runtime_interaction.claim_dispatch!
    assert_equal [ "cancelled", "author_not_member" ], dispatch.reload.values_at(:status, :reason)
  end

  test "keys are per conversation and per person" do
    first = conversation_with(@agent)
    second = conversation_with(@agent)
    invoke(first, "invoke-00000001", @agent)
    invoke(second, "invoke-00000001", @agent)
    assert_response :accepted
    assert_equal 2, MessageDispatch.where(client_invocation_id: "invoke-00000001").count
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
      invoke(chat, "invoke-00000001")
    end
    assert_error :not_found, "not_found"
  end

  private

  def invoke(chat, key, agent = nil)
    params = { client_invocation_id: key }
    params[:agent_id] = agent.to_param if agent
    post "/api/app/v1/conversations/#{chat.to_param}/invoke", params: params, headers: bearer(@tokens)
  end

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
