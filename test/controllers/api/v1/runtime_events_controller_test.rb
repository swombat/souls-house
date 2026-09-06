require "test_helper"

class Api::V1::RuntimeEventsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @agent = agents(:research_assistant)
    @chat = @agent.account.chats.create!(title: "Activity API", manual_responses: true, agents: [ @agent ])
    @run = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat)
    @run.claim_dispatch!
    @token = @run.activity_configuration![:token]
    @payload = {
      schema_version: 1, run_id: @run.run_id, attempt_id: SecureRandom.uuid, attempt_number: 1,
      events: [ { seq: 1, type: "attempt.started", data: { narration_capability: "unsupported" } } ]
    }
    @path = "/api/v1/runtime_runs/#{@run.run_id}/events"
  end

  test "valid callback persists activity and acknowledges without resident API credentials" do
    post @path, params: @payload, as: :json, headers: { Authorization: "Bearer #{@token}" }
    assert_response :success
    assert response.parsed_body["accepted"]
    assert_equal 1, @run.agent_runtime_attempts.count
  end

  test "foreign and expired credentials cannot write events" do
    post @path, params: @payload, as: :json, headers: { Authorization: "Bearer wrong" }
    assert_response :unauthorized
    @run.update!(activity_token_expires_at: 1.minute.ago)
    post @path, params: @payload, as: :json, headers: { Authorization: "Bearer #{@token}" }
    assert_response :unauthorized
    assert_empty @run.agent_runtime_attempts
  end

  test "foreign run binding malformed body and oversized body are rejected" do
    post @path, params: @payload.merge(run_id: SecureRandom.uuid), as: :json, headers: { Authorization: "Bearer #{@token}" }
    assert_response :unprocessable_entity
    post @path, params: "x" * 65_537, headers: { Authorization: "Bearer #{@token}", "CONTENT_TYPE" => "application/json" }
    assert_response :payload_too_large
  end

  test "revoked conversation membership stops reporting" do
    @chat.chat_agents.delete_all
    post @path, params: @payload, as: :json, headers: { Authorization: "Bearer #{@token}" }
    assert_response :unauthorized
  end

  test "only the resident can set its narration preference" do
    owner_key = ApiKey.generate_for(@agent.account.owner, name: "owner")
    patch "/api/v1/agent/activity_preferences", params: { share_working_narration: true },
      as: :json, headers: { Authorization: "Bearer #{owner_key.raw_token}" }
    assert_response :forbidden
    resident_key = ApiKey.generate_for(@agent.account.owner, name: "resident", agent: @agent)
    patch "/api/v1/agent/activity_preferences", params: { share_working_narration: true },
      as: :json, headers: { Authorization: "Bearer #{resident_key.raw_token}" }
    assert_response :success
    assert @agent.reload.share_working_narration?
  end

  test "replies link to their run but a different chat cannot claim that run" do
    key = ApiKey.generate_for(@agent.account.owner, name: "resident", agent: @agent)
    headers = { Authorization: "Bearer #{key.raw_token}" }
    post api_v1_conversation_messages_path(@chat), params: { content: "First reply", runtime_run_id: @run.run_id },
      as: :json, headers: headers
    assert_response :created
    assert_equal @run, @chat.messages.last.runtime_interaction
    assert @run.visible_in_chat_timeline?
    other = @agent.account.chats.create!(title: "Other", manual_responses: true, agents: [ @agent ])
    post api_v1_conversation_messages_path(other), params: { content: "Wrong", runtime_run_id: @run.run_id },
      as: :json, headers: headers
    assert_response :not_found
  end

end
