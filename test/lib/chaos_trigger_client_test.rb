require "test_helper"
require "webmock/minitest"

class ChaosTriggerClientTest < ActiveSupport::TestCase

  test "sends optional provider, model, reasoning effort, and auth mode in trigger payload" do
    stub = stub_request(:post, "https://agent.example.com/trigger")
      .with do |request|
        body = JSON.parse(request.body)
        body.fetch("provider") == "anthropic" &&
          body.fetch("model") == "claude-opus-4-7" &&
          body.fetch("reasoning_effort") == "high" &&
          body.fetch("auth_mode") == "oauth_account" &&
          body.fetch("timeout_secs") == 1800
      end
      .to_return(status: 200, body: { status: "ok" }.to_json)

    result = ChaosTriggerClient.new("https://agent.example.com", "tr_valid").request_response(
      conversation_id: nil,
      requested_by: "test",
      session_id: "session",
      request: "hello",
      trigger_kind: "orientation",
      provider: "anthropic",
      model: "claude-opus-4-7",
      reasoning_effort: "high",
      auth_mode: "oauth_account",
      read_timeout: 1830,
      runtime_timeout_secs: 1800
    )

    assert_equal 200, result[:status]
    assert_requested stub
  end

  test "omits reasoning effort when the provider default is selected" do
    stub = stub_request(:post, "https://agent.example.com/trigger")
      .with do |request|
        !JSON.parse(request.body).key?("reasoning_effort")
      end
      .to_return(status: 200, body: { status: "ok" }.to_json)

    ChaosTriggerClient.new("https://agent.example.com", "tr_valid").request_response(
      conversation_id: "conversation-1",
      requested_by: "person@example.com",
      session_id: "session-1",
      request: "Hello",
      reasoning_effort: "default"
    )

    assert_requested stub
  end

  test "defaults runtime timeout to thirty minutes" do
    stub = stub_request(:post, "https://agent.example.com/trigger")
      .with do |request|
        JSON.parse(request.body).fetch("timeout_secs") == 1800
      end
      .to_return(status: 200, body: { status: "ok" }.to_json)

    result = ChaosTriggerClient.new("https://agent.example.com", "tr_valid").request_response(
      conversation_id: nil,
      requested_by: "test",
      session_id: "session",
      request: "hello"
    )

    assert_equal 200, result[:status]
    assert_requested stub
  end

  test "omits request_delta and persistent_session from body by default" do
    stub = stub_request(:post, "https://agent.example.com/trigger")
      .with do |request|
        body = JSON.parse(request.body)
        !body.key?("request_delta") && !body.key?("persistent_session")
      end
      .to_return(status: 200, body: { status: "ok" }.to_json)

    ChaosTriggerClient.new("https://agent.example.com", "tr_valid").request_response(
      conversation_id: nil,
      requested_by: "test",
      session_id: "session",
      request: "hello"
    )

    assert_requested stub
  end

  test "includes request_delta and persistent_session when given" do
    stub = stub_request(:post, "https://agent.example.com/trigger")
      .with do |request|
        body = JSON.parse(request.body)
        body.fetch("request_delta") == "slim delta prompt" && body.fetch("persistent_session") == true && body.fetch("request") == "full prompt"
      end
      .to_return(status: 200, body: { status: "ok" }.to_json)

    ChaosTriggerClient.new("https://agent.example.com", "tr_valid").request_response(
      conversation_id: nil,
      requested_by: "test",
      session_id: "session",
      request: "full prompt",
      request_delta: "slim delta prompt",
      persistent_session: true
    )

    assert_requested stub
  end

  test "includes channel-specific trigger payload without replacing standard fields" do
    stub = stub_request(:post, "https://agent.example.com/trigger")
      .with do |request|
        body = JSON.parse(request.body)
        body["channel"] == "telegram" &&
          body["thread_id"] == "thread-1" &&
          body["request"] == "canonical request"
      end
      .to_return(status: 200, body: { status: "ok" }.to_json)

    ChaosTriggerClient.new("https://agent.example.com", "tr_valid").request_response(
      conversation_id: "thread-1",
      requested_by: "test",
      session_id: "session",
      request: "canonical request",
      trigger_payload: { channel: "telegram", thread_id: "thread-1", request: "cannot replace" }
    )

    assert_requested stub
  end

  test "sends the session policy only with persistent sessions" do
    policy = { idle_timeout_secs: 2700, max_age_secs: 14_400, context_budget_tokens: 300_000 }
    persistent = stub_request(:post, "https://agent.example.com/trigger")
      .with { |request| JSON.parse(request.body)["session_policy"] == policy.stringify_keys }
      .to_return(status: 200, body: { status: "ok" }.to_json)

    client = ChaosTriggerClient.new("https://agent.example.com", "tr_valid")
    client.request_response(conversation_id: nil, requested_by: "test", session_id: "s", request: "hi",
      persistent_session: true, session_policy: policy)
    assert_requested persistent

    remove_request_stub(persistent)
    fresh = stub_request(:post, "https://agent.example.com/trigger")
      .with { |request| !JSON.parse(request.body).key?("session_policy") }
      .to_return(status: 200, body: { status: "ok" }.to_json)
    client.request_response(conversation_id: nil, requested_by: "test", session_id: "s", request: "hi",
      persistent_session: false, session_policy: policy)
    assert_requested fresh
  end

end
