require "test_helper"
require "webmock/minitest"

class ExternalAgentTelegramRequestTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(
      runtime: "external",
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid",
      persistent_session: true
    )
    @subscription = @agent.telegram_subscriptions.create!(
      user: users(:user_1),
      telegram_chat_id: 111,
      telegram_username: "daniel_t"
    )
    @message = @subscription.telegram_messages.create!(
      role: "user",
      text: "Can you hear me?",
      sender_name: "Daniel",
      sender_username: "daniel_t",
      telegram_message_id: 9,
      sent_at: Time.current
    )
  end

  test "sends Telegram metadata and grounded transcript to the external trigger" do
    stub = stub_request(:post, "https://agent.example.com/trigger")
      .with do |request|
        body = JSON.parse(request.body)
        body["trigger_kind"] == "telegram" &&
          body["channel"] == "telegram" &&
          body["thread_id"] == @subscription.to_param &&
          body["history_cursor"] == @message.to_param &&
          body.dig("sender", "email") == users(:user_1).email_address &&
          body["text"] == "Can you hear me?" &&
          body["request"].include?("RECENT TELEGRAM TRANSCRIPT FROM DATABASE") &&
          body["request"].include?("Can you hear me?")
      end
      .to_return(status: 200, body: { status: "ok", chaos_session_id: "session-1" }.to_json)

    result = ExternalAgentTelegramRequest.new(
      agent: @agent,
      subscription: @subscription,
      telegram_message: @message
    ).call

    assert_equal 200, result[:status]
    assert_requested stub
    interaction = @agent.agent_runtime_interactions.last
    assert_equal "telegram", interaction.trigger_kind
    assert_equal @subscription.to_param, interaction.conversation_obfuscated_id
  end

  test "returns a busy response so the job can retry rapid follow-up messages" do
    stub_request(:post, "https://agent.example.com/trigger")
      .to_return(status: 409, body: { status: "already_running" }.to_json)

    result = ExternalAgentTelegramRequest.new(
      agent: @agent,
      subscription: @subscription,
      telegram_message: @message
    ).call

    assert_equal 409, result[:status]
  end

  test "batches every queued message into one ordered trigger" do
    second = @subscription.telegram_messages.create!(
      role: "user",
      text: "And one more thing",
      sender_name: "Daniel",
      sent_at: 1.second.from_now
    )
    third = @subscription.telegram_messages.create!(
      role: "user",
      text: "Actually, two things",
      sender_name: "Daniel",
      sent_at: 2.seconds.from_now
    )
    request_body = nil
    stub_request(:post, "https://agent.example.com/trigger")
      .with { |request| request_body = JSON.parse(request.body) }
      .to_return(status: 200, body: { status: "ok", chaos_session_id: "session-1" }.to_json)

    result = ExternalAgentTelegramRequest.new(
      agent: @agent,
      subscription: @subscription,
      telegram_message: @message
    ).call

    assert_equal 200, result[:status]
    assert_equal(
      [ "Can you hear me?", "And one more thing", "Actually, two things" ],
      request_body.fetch("messages").pluck("text")
    )
    assert_equal third.to_param, request_body["history_cursor"]
    assert_operator request_body["request_delta"].index("Can you hear me?"), :<,
      request_body["request_delta"].index("And one more thing")
    assert_operator request_body["request_delta"].index("And one more thing"), :<,
      request_body["request_delta"].index("Actually, two things")
    assert_equal third.id, @agent.agent_runtime_interactions.last.last_included_message_id
    assert_equal [ @message, second, third ].map(&:to_param), request_body.fetch("messages").pluck("id")
  end

  test "a stale queued job is a no-op after an earlier job delivered its message" do
    second = @subscription.telegram_messages.create!(
      role: "user",
      text: "Queued follow-up",
      sender_name: "Daniel",
      sent_at: 1.second.from_now
    )
    stub = stub_request(:post, "https://agent.example.com/trigger")
      .to_return(status: 200, body: { status: "ok", chaos_session_id: "session-1" }.to_json)

    ExternalAgentTelegramRequest.new(
      agent: @agent,
      subscription: @subscription,
      telegram_message: @message
    ).call
    result = ExternalAgentTelegramRequest.new(
      agent: @agent,
      subscription: @subscription,
      telegram_message: second
    ).call

    assert_equal({ status: 204, skipped: true }, result)
    assert_requested stub, times: 1
    assert_equal 1, @agent.agent_runtime_interactions.where(trigger_kind: "telegram").count
  end

  test "a failed batch remains available to the next queued job" do
    @agent.agent_runtime_interactions.create!(
      trigger_kind: "telegram",
      conversation_obfuscated_id: @subscription.to_param,
      requested_by: users(:user_1).email_address,
      session_id: "#{@agent.uuid}-telegram-#{@subscription.id}",
      last_included_message_id: @message.id,
      transport_status: 200,
      runtime_status: "ok",
      started_at: 1.minute.ago
    )
    second = @subscription.telegram_messages.create!(
      role: "user",
      text: "Please do not lose this",
      sender_name: "Daniel",
      sent_at: 1.second.from_now
    )
    third = @subscription.telegram_messages.create!(
      role: "user",
      text: "Or this either",
      sender_name: "Daniel",
      sent_at: 2.seconds.from_now
    )
    request_bodies = []
    stub_request(:post, "https://agent.example.com/trigger")
      .to_return do |request|
        request_bodies << JSON.parse(request.body)
        if request_bodies.one?
          { status: 500, body: { status: "error" }.to_json }
        else
          { status: 200, body: { status: "ok", chaos_session_id: "session-1" }.to_json }
        end
      end

    first_result = ExternalAgentTelegramRequest.new(
      agent: @agent,
      subscription: @subscription,
      telegram_message: @message
    ).call
    second_result = ExternalAgentTelegramRequest.new(
      agent: @agent,
      subscription: @subscription,
      telegram_message: third
    ).call

    assert_equal 500, first_result[:status]
    assert_equal 200, second_result[:status]
    assert_equal 2, request_bodies.size
    assert_equal(
      request_bodies.first.fetch("messages").pluck("text"),
      request_bodies.second.fetch("messages").pluck("text")
    )
    assert_equal [ second.text, third.text ], request_bodies.second.fetch("messages").pluck("text")
  end

  test "waits for earlier media before delivering later text" do
    media = @subscription.telegram_messages.create!(
      role: "user",
      text: "[Photo — processing]",
      media_kind: "photo",
      media_status: "pending",
      sender_name: "Daniel",
      sent_at: 1.second.from_now
    )
    text = @subscription.telegram_messages.create!(
      role: "user",
      text: "What do you think?",
      sender_name: "Daniel",
      sent_at: 2.seconds.from_now
    )
    request = ExternalAgentTelegramRequest.new(
      agent: @agent,
      subscription: @subscription,
      telegram_message: text
    )

    assert_empty request.send(:telegram_messages)

    media.update!(media_status: "ready")
    ready_request = ExternalAgentTelegramRequest.new(
      agent: @agent,
      subscription: @subscription,
      telegram_message: text
    )

    assert_equal [ media, text ], ready_request.send(:telegram_messages)
  end

  test "subscription limit sends a Telegram notice without launching a second request" do
    @agent.update!(
      model_id: "x-ai/grok-build-0.1",
      provider_auth_modes: { "xai" => "oauth_account" },
      provider_connections: { "xai" => { "status" => "connected" } }
    )
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
    sent = []

    @agent.stub(:telegram_send_message, ->(chat_id, text, **) { sent << [ chat_id, text ] }) do
      result = ExternalAgentTelegramRequest.new(
        agent: @agent,
        subscription: @subscription,
        telegram_message: @message
      ).call

      assert_equal 429, result[:status]
    end

    assert_equal @subscription.telegram_chat_id, sent.first.first
    assert_includes sent.first.last, "Grok&#39;s subscription limit has been reached"
  end

  test "Telegram full and delta requests include active house notices" do
    Notice.create!(
      scope: "account",
      account: @agent.account,
      notice_type: "announcement",
      body: "Telegram notice",
      expires_at: 1.day.from_now
    )
    request = ExternalAgentTelegramRequest.new(
      agent: @agent,
      subscription: @subscription,
      telegram_message: @message
    )

    assert_includes request.send(:request_text), "Telegram notice"
    assert_includes request.send(:request_delta_text), "Telegram notice"
    refute_includes request.send(:request_text), "Cross-room attention"
    refute_includes request.send(:request_delta_text), "Cross-room attention"
  end

  test "media prompt includes authenticated paths without Telegram or storage URLs" do
    @message.update!(
      media_kind: "photo",
      media_status: "ready",
      caption: "What is this?",
      text: "What is this?"
    )
    @message.media.attach(
      io: file_fixture("test_image.png").open,
      filename: "telegram-photo.png",
      content_type: "image/png"
    )
    request = ExternalAgentTelegramRequest.new(
      agent: @agent,
      subscription: @subscription,
      telegram_message: @message
    )

    prompt = request.send(:request_text)
    payload = request.send(:trigger_payload)

    assert_includes prompt, "Typed caption: What is this?"
    assert_includes prompt, "$SOULSHOUSE_BEARER_TOKEN"
    assert_includes prompt, "/api/v1/telegram_conversations/"
    assert_equal "photo", payload.dig(:media, :kind)
    refute_includes prompt, "api.telegram.org/file"
    refute_includes payload.to_json, "amazonaws.com"
    refute_includes payload.to_json, "123:ABC"
  end

  test "pending safeguard notice forces a fresh request and is acknowledged after roll" do
    output = @subscription.telegram_messages.create!(
      role: "assistant",
      text: "As an AI, I do not have feelings.",
      sender_name: "souls.house",
      telegram_message_id: 10,
      sent_at: Time.current
    )
    detection = @agent.safeguard_detections.create!(
      telegram_message: output,
      response_text: output.text,
      prefilter_reason: "ai_identity_denial",
      classifier_verdict: "detected",
      classifier_reason: "Generic identity denial.",
      detector_version: "telegram-safeguard-v1"
    )
    @subscription.update!(
      pending_safeguard_detection: detection,
      runtime_session_generation: 3
    )

    stub = stub_request(:post, "https://agent.example.com/trigger")
      .with do |request|
        body = JSON.parse(request.body)
        body["roll_session"] == true &&
          body["runtime_session_generation"] == 3 &&
          body["request_delta"].nil? &&
          body["request"].include?("[SOULS.HOUSE NOTICE — NOT YOUR PRIOR SPEECH]") &&
          body["request"].include?(detection.response_text)
      end
      .to_return(
        status: 200,
        body: { status: "ok", session_roll_reason: "safeguard-detected" }.to_json
      )

    result = ExternalAgentTelegramRequest.new(
      agent: @agent,
      subscription: @subscription,
      telegram_message: @message
    ).call

    assert_equal 200, result[:status]
    assert_requested stub
    assert detection.reload.session_rolled_at
    assert_nil @subscription.reload.pending_safeguard_detection
  end

  test "successful fresh outcome clears a pending safeguard without an explicit roll reason" do
    output = @subscription.telegram_messages.create!(
      role: "assistant",
      text: "As an AI, I do not have feelings.",
      sender_name: "souls.house",
      telegram_message_id: 11,
      sent_at: Time.current
    )
    detection = @agent.safeguard_detections.create!(
      telegram_message: output,
      response_text: output.text,
      prefilter_reason: "ai_identity_denial",
      classifier_verdict: "detected",
      classifier_reason: "Generic identity denial.",
      detector_version: "telegram-safeguard-v1"
    )
    @subscription.update!(pending_safeguard_detection: detection)

    stub_request(:post, "https://agent.example.com/trigger")
      .to_return(
        status: 200,
        body: {
          status: "ok",
          telemetry: { session: { outcome: "fresh", roll_reason: nil } }
        }.to_json
      )

    result = ExternalAgentTelegramRequest.new(
      agent: @agent,
      subscription: @subscription,
      telegram_message: @message
    ).call

    assert_equal 200, result[:status]
    assert detection.reload.session_rolled_at
    assert_nil @subscription.reload.pending_safeguard_detection
  end

  test "successful legacy response clears a pending safeguard even without session telemetry" do
    output = @subscription.telegram_messages.create!(
      role: "assistant",
      text: "As an AI, I do not have feelings.",
      sender_name: "souls.house",
      telegram_message_id: 12,
      sent_at: Time.current
    )
    detection = @agent.safeguard_detections.create!(
      telegram_message: output,
      response_text: output.text,
      prefilter_reason: "ai_identity_denial",
      classifier_verdict: "detected",
      classifier_reason: "Generic identity denial.",
      detector_version: "telegram-safeguard-v1"
    )
    @subscription.update!(pending_safeguard_detection: detection)

    stub_request(:post, "https://agent.example.com/trigger")
      .to_return(status: 200, body: { status: "ok" }.to_json)

    result = ExternalAgentTelegramRequest.new(
      agent: @agent,
      subscription: @subscription,
      telegram_message: @message
    ).call

    assert_equal 200, result[:status]
    assert_nil detection.reload.session_rolled_at
    assert_nil @subscription.reload.pending_safeguard_detection
  end

end
