require "test_helper"
require "webmock/minitest"

class ExternalAgentResponseRequestTest < ActiveSupport::TestCase

  test "trigger request points external agent at the API skill file" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "External prompt")
    chat.messages.create!(role: "user", content: "Can you see this transcript?")
    request = ExternalAgentResponseRequest.new(agent: agent, chat: chat)
    text = request.send(:request_text)

    assert_includes text, "HELIXKIT_BEARER_TOKEN"
    assert_includes text, "helixkit-post-message"
    assert_includes text, "/usr/local/share/helixkit-agent/helixkit-api.md"
    assert_includes text, "Prefer piping the message through stdin"
    assert_includes text, "Do not put prose containing `$`, backticks"
    assert_includes text, "explicit user request"
    assert_includes text, "normally expecting a visible reply"
    assert_includes text, "final answer in this Chaos runtime is diagnostic stdout only"
    assert_includes text, "must post it to HelixKit yourself before exiting"
    assert_includes text, "no separate confirmation is needed"
    assert_includes text, "default for this trigger is that you post a reply"
    assert_includes text, "choosing not to is also a valid response"
    assert_includes text, "already authorized"
    assert_includes text, "post your own messages"
    assert_includes text, "stdout is diagnostic only"
    assert_includes text, "explain your reason briefly on stdout"
    assert_includes text, "Conversation metadata"
    assert_includes text, "title: External prompt"
    assert_includes text, "agent_only: false"
    assert_includes text, "LIVE HELIXKIT TRANSCRIPT FROM DATABASE"
    assert_includes text, "message_count_included: 1"
    assert_includes text, "BEGIN LIVE HELIXKIT TRANSCRIPT FROM DATABASE"
    assert_includes text, "END LIVE HELIXKIT TRANSCRIPT FROM DATABASE"
    assert_includes text, "Only the LIVE HELIXKIT TRANSCRIPT section above is the current stored conversation transcript"
    assert_includes text, "Can you see this transcript?"
    refute_includes text, "Cross-room attention"

    # Sovereignty guard: assistant-pattern nudges that previously crept in.
    # The agent's outputs are messages, not "assistant messages"; the trigger
    # is an invitation, not a "decide and act now" imperative; the transcript
    # is rendered with names, not role labels like "user (..." / "assistant (...".
    refute_includes text, "post your own assistant messages"
    refute_includes text, "Do not offer to post later"
    refute_includes text, "decide and act now"
    refute_includes text, "Do not ask for a second confirmation"
    refute_includes text, "asking you to act"
  end

  test "agent-only trigger softens expectation to post" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "[AGENT-ONLY] Quiet room")
    chat.agents << agent
    chat.messages.create!(role: "assistant", agent: agent, content: "Room quiet.")

    text = ExternalAgentResponseRequest.new(agent: agent, chat: chat).send(:request_text)

    assert_includes text, "agent_only: true"
    assert_includes text, "the trigger is an invitation to inspect the live state"
    assert_includes text, "If the live transcript contains a direct human request for you"
    assert_includes text, "a visible reply may be useful but silence is often correct"
    assert_includes text, "Do not post merely to acknowledge wakefulness or continue room weather"
    refute_includes text, "normally expecting a visible reply"
    refute_includes text, "The default for this trigger is that you post a reply"
  end

  test "trigger transcript exposes authenticated attachment download paths" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Attached document")
    message = chat.messages.create!(role: "user", content: "Please read the attached draft")
    message.attachments.attach(
      io: file_fixture("test_document.pdf").open,
      filename: "draft.pdf",
      content_type: "application/pdf"
    )

    text = ExternalAgentResponseRequest.new(agent: agent, chat: chat).send(:request_text)
    attachment = message.attachments_attachments.first

    assert_includes text, "Attachments (fetch with"
    assert_includes text, "filename: draft.pdf"
    assert_includes text, "content_type: application/pdf"
    assert_includes text, Rails.application.routes.url_helpers.api_v1_conversation_message_attachment_path(
      chat,
      message,
      attachment
    )
    assert_includes text, "HELIXKIT_BEARER_TOKEN"
  end

  test "trigger transcript exposes agent-posted image download paths" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Generated image")
    chat.agents << agent
    message = chat.messages.create!(role: "assistant", agent: agent, content: "I made this.")
    message.attachments.attach(
      io: file_fixture("test_image.png").open,
      filename: "generated.png",
      content_type: "image/png"
    )

    text = ExternalAgentResponseRequest.new(agent: agent, chat: chat).send(:request_text)
    attachment = message.attachments_attachments.first

    assert_includes text, "#{agent.name}: I made this."
    assert_includes text, "filename: generated.png"
    assert_includes text, "content_type: image/png"
    assert_includes text, Rails.application.routes.url_helpers.api_v1_conversation_message_attachment_path(
      chat,
      message,
      attachment
    )
  end

  test "full transcript keeps recent messages within the runtime byte budget" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Long transcript")
    messages = 6.times.map do |index|
      chat.messages.create!(
        role: "user",
        content: "message-#{index}-#{("x" * 20_000)}"
      )
    end

    request = ExternalAgentResponseRequest.new(agent: agent, chat: chat)
    text = request.send(:request_text)

    assert_operator text.bytesize, :<, 90_000
    assert_includes text, "message-5-"
    refute_includes text, "message-0-"
    assert_match(/messages_omitted_before_window: [1-9]/, text)
    assert_equal messages.last.id, request.send(:computed_last_included_message_id)
  end

  test "oversized latest message is truncated without breaking unicode" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Oversized message")
    message = chat.messages.create!(role: "user", content: "é" * 50_000)

    request = ExternalAgentResponseRequest.new(agent: agent, chat: chat)
    text = request.send(:request_text)

    assert text.valid_encoding?
    assert_operator text.bytesize, :<, 90_000
    assert_includes text, "Message truncated to fit the external runtime transcript budget"
    assert_equal message.id, request.send(:computed_last_included_message_id)
  end

  test "records runtime stdout and stderr when triggering external agent" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "External prompt")
    agent.update!(
      runtime: "external",
      uuid: SecureRandom.uuid_v7,
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid",
      health_state: "healthy",
      consecutive_health_failures: 0
    )
    stub_request(:post, "https://agent.example.com/trigger")
      .to_return(
        status: 200,
        body: {
          status: "ok",
          returncode: 0,
          stdout: "runtime said hello",
          stderr: "runtime diagnostics",
          full_invocation_text: "SOUL\n\nLIVE REQUEST\n\nMEMORY"
        }.to_json
      )

    assert_difference "AgentRuntimeInteraction.count", 1 do
      ExternalAgentResponseRequest.new(agent: agent, chat: chat).call
    end

    interaction = AgentRuntimeInteraction.last
    assert_equal agent, interaction.agent
    assert_equal chat, interaction.chat
    assert_equal "conversation", interaction.trigger_kind
    assert_equal 200, interaction.transport_status
    assert_equal "ok", interaction.runtime_status
    assert_equal "runtime said hello", interaction.stdout
    assert_equal "runtime diagnostics", interaction.stderr
    assert_equal "SOUL\n\nLIVE REQUEST\n\nMEMORY", interaction.full_invocation_text
    refute_includes interaction.response_body.keys, "full_invocation_text"
  end

  test "subscription authentication failures surface a reconnect link instead of raw provider errors" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openai/gpt-5", title: "Expired subscription")
    agent.update!(
      model_id: "openai/gpt-5",
      runtime: "external",
      uuid: SecureRandom.uuid_v7,
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid",
      health_state: "healthy",
      provider_auth_modes: { "openai" => "oauth_account" },
      provider_connections: {
        "openai" => {
          "status" => "connected",
          "email" => "subscriber@example.com"
        }
      }
    )
    stub_request(:post, "https://agent.example.com/trigger")
      .to_return(
        status: 500,
        body: {
          status: "error",
          returncode: 1,
          error_kind: "auth_expired"
        }.to_json
      )

    assert_difference "chat.messages.count", 1 do
      ExternalAgentResponseRequest.new(agent: agent, chat: chat).call
    end

    message = chat.messages.order(:created_at).last
    assert_equal agent, message.agent
    assert_includes message.content, "Provider connection expired"
    assert_includes message.content, Rails.application.routes.url_helpers.edit_account_agent_path(
      agent.account,
      agent,
      tab: "hosting"
    )
    assert_not_includes message.content, "401 Unauthorized"
    assert_equal "expired", agent.reload.provider_connection("openai").fetch("status")
    assert_equal "oauth_account", AgentRuntimeInteraction.order(:created_at).last.provider_auth_mode
  end

  test "subscription limit creates a reset message and keeps the connection active" do
    agent = agents(:research_assistant)
    agent.update!(
      model_id: "x-ai/grok-build-0.1",
      runtime: "external",
      uuid: SecureRandom.uuid_v7,
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid",
      health_state: "healthy",
      provider_auth_modes: { "xai" => "oauth_account" },
      provider_connections: { "xai" => { "status" => "connected" } }
    )
    chat = agent.account.chats.create!(model_id: "x-ai/grok-build-0.1", title: "Exhausted subscription")
    chat.messages.create!(role: "user", user: users(:user_1), content: "Hello Grok")
    stub_request(:post, "https://agent.example.com/trigger").to_return(
      status: 429,
      body: {
        status: "error",
        error_kind: "subscription_limit",
        subscription_usage: {
          provider: "xai",
          status: "limited",
          windows: [
            {
              blocking: true,
              remaining_percent: 0,
              resets_at: 2.hours.from_now.iso8601
            }
          ]
        }
      }.to_json
    )

    assert_difference "chat.messages.count", 1 do
      ExternalAgentResponseRequest.new(agent:, chat:).call
    end

    assert_includes chat.messages.order(:created_at).last.content, "Grok's subscription limit has been reached"
    assert_equal "connected", agent.reload.provider_connection("xai").fetch("status")
    assert_equal 429, AgentRuntimeInteraction.order(:created_at).last.transport_status
  end

  test "does not build a request_delta when persistent_session is disabled" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Delta prompt")
    chat.messages.create!(role: "user", content: "Hello")

    request = ExternalAgentResponseRequest.new(agent: agent, chat: chat)

    assert_nil request.send(:request_delta_text)
  end

  test "does not build a request_delta on the first turn even when persistent_session is enabled" do
    agent = agents(:research_assistant)
    agent.update!(persistent_session: true)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Delta prompt")
    chat.messages.create!(role: "user", content: "Hello")

    request = ExternalAgentResponseRequest.new(agent: agent, chat: chat)

    assert_nil request.send(:request_delta_text)
    assert_equal chat.messages.maximum(:id), request.send(:computed_last_included_message_id)
  end

  test "builds a request_delta containing only messages after the prior cursor" do
    agent = agents(:research_assistant)
    agent.update!(persistent_session: true)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Delta prompt")
    first = chat.messages.create!(role: "user", content: "First message")
    AgentRuntimeInteraction.create!(
      agent: agent, chat: chat, trigger_kind: "conversation", session_id: "s",
      requested_by: "test", started_at: 1.minute.ago, last_included_message_id: first.id,
      chaos_session_id: "chaos-1", transport_status: 200, runtime_status: "ok"
    )
    second = chat.messages.create!(role: "user", content: "Second message")

    request = ExternalAgentResponseRequest.new(agent: agent, chat: chat)
    delta = request.send(:request_delta_text)

    assert_includes delta, "LIVE HELIXKIT TRANSCRIPT DELTA FROM DATABASE"
    assert_includes delta, "messages_after_cursor: #{first.id}"
    assert_includes delta, "message_count_included: 1"
    assert_includes delta, "Second message"
    refute_includes delta, "First message"
    assert_includes delta, "Treat these new messages as ground truth for recent conversation activity"
    assert_includes delta, "Current time:"
    refute_includes delta, "must post it to HelixKit yourself before exiting"
    refute_includes delta, "Cross-room attention"
    assert_equal second.id, request.send(:computed_last_included_message_id)
  end

  test "failed runtime attempts do not advance the persistent transcript cursor" do
    agent = agents(:research_assistant)
    agent.update!(persistent_session: true)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Delta prompt")
    first = chat.messages.create!(role: "user", content: "First message")
    AgentRuntimeInteraction.create!(
      agent: agent, chat: chat, trigger_kind: "conversation", session_id: "s",
      requested_by: "test", started_at: 3.minutes.ago, finished_at: 2.minutes.ago,
      last_included_message_id: first.id, chaos_session_id: "chaos-1",
      transport_status: 200, runtime_status: "ok"
    )
    second = chat.messages.create!(role: "user", content: "Second message")
    AgentRuntimeInteraction.create!(
      agent: agent, chat: chat, trigger_kind: "conversation", session_id: "s",
      requested_by: "test", started_at: 1.minute.ago, finished_at: Time.current,
      last_included_message_id: second.id, chaos_session_id: "chaos-1",
      transport_status: 504, runtime_status: "timeout"
    )

    request = ExternalAgentResponseRequest.new(agent: agent, chat: chat)
    delta = request.send(:request_delta_text)

    assert_includes delta, "messages_after_cursor: #{first.id}"
    assert_includes delta, "Second message"
    assert_equal second.id, request.send(:computed_last_included_message_id)
  end

  test "persistent cursor records the exact delta snapshot even if a message arrives later" do
    agent = agents(:research_assistant)
    agent.update!(persistent_session: true)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Delta prompt")
    first = chat.messages.create!(role: "user", content: "First message")
    AgentRuntimeInteraction.create!(
      agent: agent, chat: chat, trigger_kind: "conversation", session_id: "s",
      requested_by: "test", started_at: 1.minute.ago, last_included_message_id: first.id,
      chaos_session_id: "chaos-1", transport_status: 200, runtime_status: "ok"
    )
    second = chat.messages.create!(role: "user", content: "Second message")

    request = ExternalAgentResponseRequest.new(agent: agent, chat: chat)
    delta = request.send(:request_delta_text)
    third = chat.messages.create!(role: "user", content: "Arrived after prompt snapshot")

    assert_includes delta, "Second message"
    refute_includes delta, "Arrived after prompt snapshot"
    assert_equal second.id, request.send(:computed_last_included_message_id)
    assert_operator third.id, :>, request.send(:computed_last_included_message_id)
  end

  test "sends an empty delta block with zero count when no new messages exist since the cursor" do
    agent = agents(:research_assistant)
    agent.update!(persistent_session: true)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Delta prompt")
    only = chat.messages.create!(role: "user", content: "Only message")
    AgentRuntimeInteraction.create!(
      agent: agent, chat: chat, trigger_kind: "conversation", session_id: "s",
      requested_by: "test", started_at: 1.minute.ago, last_included_message_id: only.id,
      chaos_session_id: "chaos-1", transport_status: 200, runtime_status: "ok"
    )

    request = ExternalAgentResponseRequest.new(agent: agent, chat: chat)
    delta = request.send(:request_delta_text)

    assert_includes delta, "message_count_included: 0"
    assert_includes delta, "_No new messages._"
    assert_equal only.id, request.send(:computed_last_included_message_id)
  end

  test "call sends persistent_session and request_delta, and records usage and session fields on resume" do
    agent = agents(:research_assistant)
    agent.update!(
      runtime: "external",
      uuid: SecureRandom.uuid_v7,
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid",
      health_state: "healthy",
      consecutive_health_failures: 0,
      persistent_session: true
    )
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Delta prompt")
    first = chat.messages.create!(role: "user", content: "First message")
    AgentRuntimeInteraction.create!(
      agent: agent, chat: chat, trigger_kind: "conversation", session_id: "s",
      requested_by: "test", started_at: 2.minutes.ago, finished_at: 1.minute.ago,
      last_included_message_id: first.id, chaos_session_id: "chaos-1",
      transport_status: 200, runtime_status: "ok"
    )
    second = chat.messages.create!(role: "user", content: "Second message")

    stub = stub_request(:post, "https://agent.example.com/trigger")
      .with do |http_request|
        body = JSON.parse(http_request.body)
        body["persistent_session"] == true &&
          body["request_delta"].to_s.include?("Second message") &&
          !body["request_delta"].to_s.include?("First message") &&
          body["request"].to_s.include?("First message")
      end
      .to_return(
        status: 200,
        body: {
          status: "ok",
          chaos_session_id: "chaos-123",
          session_resumed: true,
          fresh_fallback: false,
          usage: { "input_tokens" => 10, "cached_input_tokens" => 5, "output_tokens" => 3 }
        }.to_json
      )

    ExternalAgentResponseRequest.new(agent: agent, chat: chat).call

    assert_requested stub
    interaction = AgentRuntimeInteraction.last
    assert_equal second.id, interaction.last_included_message_id
    assert_equal "chaos-123", interaction.chaos_session_id
    assert interaction.session_resumed
    assert_not interaction.fresh_fallback
    assert_equal 10, interaction.input_tokens
    assert_equal 5, interaction.cached_input_tokens
    assert_equal 3, interaction.output_tokens
  end

  test "conversation full and resumed delta requests include active house notices" do
    agent = agents(:research_assistant)
    agent.update!(persistent_session: true)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Notice delta")
    first = chat.messages.create!(role: "user", content: "First")
    AgentRuntimeInteraction.create!(
      agent: agent, chat: chat, trigger_kind: "conversation", session_id: "s",
      requested_by: "test", started_at: 1.minute.ago, last_included_message_id: first.id,
      chaos_session_id: "chaos-1", transport_status: 200, runtime_status: "ok"
    )
    Notice.create!(
      scope: "account",
      account: agent.account,
      notice_type: "announcement",
      body: "Conversation notice",
      expires_at: 1.day.from_now
    )

    request = ExternalAgentResponseRequest.new(agent: agent, chat: chat)

    assert_includes request.send(:request_text), "Conversation notice"
    assert_includes request.send(:request_delta_text), "Conversation notice"
  end

end
