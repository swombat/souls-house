require "test_helper"
require "webmock/minitest"

class ResidentFallback::HopTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper

  LIMITED = {
    status: "error", error_kind: "subscription_limit",
    subscription_usage: { provider: "xai", status: "limited", windows: [ { blocking: true, remaining_percent: 0, resets_at: "2026-11-11T14:00:00Z" } ] }
  }.freeze

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(model_id: "x-ai/grok-build-0.1", runtime: "external", uuid: SecureRandom.uuid_v7,
      endpoint_url: "https://agent.example.com", trigger_bearer_token: "tr_valid", health_state: "healthy",
      provider_auth_modes: { "xai" => "oauth_account" }, provider_connections: { "xai" => { "status" => "connected" } })
    @agent.account.update_columns(openrouter_api_key: "sk-or-own")
    # The message first, so it doesn't start a run of its own.
    @chat = @agent.account.chats.create!(model_id: "x-ai/grok-build-0.1", title: "Fallback")
    @chat.messages.create!(role: "user", user: users(:user_1), content: "Hello")
    @chat.agents << @agent
    @chat.update!(manual_responses: true)
    @triggers = []
    stub_request(:post, "https://agent.example.com/trigger").to_return do |request|
      body = JSON.parse(request.body)
      @triggers << body
      if body["provider"] == "house"
        { status: 200, body: { status: "ok", returncode: 0, chaos_session_id: "s-fb" }.to_json }
      else
        { status: 429, body: LIMITED.to_json }
      end
    end
  end

  def opt_in!(switch: true)
    Setting.instance.update!(paid_fallback_enabled: switch)
    ResidentFallbackPolicy.create!(agent: @agent, enabled: true, model_id: "anthropic/claude-sonnet-5", cap_usd: 5,
      enabled_by_user: users(:user_1), enabled_at: Time.current)
  end

  test "with no opt-in the subscription's refusal stands as before" do
    Setting.instance.update!(paid_fallback_enabled: true)
    assert_difference -> { @chat.messages.count }, 1 do
      ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call
    end
    assert_includes @chat.messages.order(:id).last.content, "subscription limit has been reached"
    assert_equal 0, ResidentFallbackTurn.count
    assert_equal 1, @triggers.size
  end

  test "with the site switch off an opted-in resident doesn't hop" do
    opt_in!(switch: false)
    ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call
    assert_equal 0, ResidentFallbackTurn.count
    assert_includes @chat.messages.order(:id).last.content, "subscription limit has been reached"
  end

  test "a pre-dispatch refusal hops the turn to the fallback lane on the house provider" do
    opt_in!
    assert_no_difference -> { @chat.messages.count } do
      ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call
    end
    turn = ResidentFallbackTurn.sole
    primary = turn.primary_interaction
    assert_equal [ "xai", primary.model, "anthropic/claude-sonnet-5" ], [ turn.primary_provider, turn.primary_model, turn.fallback_model_id ]
    assert primary.model.present?
    assert_equal Time.utc(2026, 11, 11, 14), turn.primary_resets_at
    assert primary.finished_at?

    perform_enqueued_jobs(only: ResidentFallbackHopJob)
    assert_equal 2, @triggers.size
    hop = @triggers.last
    assert_equal [ "house", "fallback/anthropic/claude-sonnet-5", "api_key" ], hop.values_at("provider", "model", "auth_mode")
    assert_equal "#{@agent.uuid}-#{@chat.id}-fallback", hop["session_id"]
    assert_nil hop["reasoning_effort"]
    assert_includes hop["request"], "Paid fallback: your subscription's allowance ran out"
    fallback = turn.reload.fallback_interaction
    assert_equal fallback.id.to_s, hop["inference_run"]
    assert_equal [ "house", "#{@agent.uuid}-#{@chat.id}-fallback" ], [ fallback.provider, fallback.session_id ]
    assert_equal "#{@agent.uuid}-#{@chat.id}", primary.session_id
  end

  test "a fallback turn never hops again, and a refusal after the run started doesn't hop" do
    opt_in!
    interaction = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat)
    interaction.update!(provider_auth_mode: "oauth_account", provider: "xai", model: "grok-build-0.1",
      session_id: "#{@agent.uuid}-#{@chat.id}-fallback")
    assert_nil ResidentFallback::Hop.after_refusal(interaction: interaction, result: { status: 429, body: LIMITED.deep_stringify_keys })
    interaction.update!(session_id: "#{@agent.uuid}-#{@chat.id}")
    post_run = { status: 200, body: { "status" => "error", "error_kind" => "subscription_limit" } }
    assert_nil ResidentFallback::Hop.after_refusal(interaction: interaction, result: post_run)
    assert ResidentFallback::Hop.after_refusal(interaction: interaction, result: { status: 429, body: LIMITED.deep_stringify_keys })
    assert_nil ResidentFallback::Hop.after_refusal(interaction: interaction, result: { status: 429, body: LIMITED.deep_stringify_keys }),
      "one hop per refused attempt"
  end

  test "a policy that can't admit a call (no own key) doesn't hop" do
    opt_in!
    @agent.account.update_columns(openrouter_api_key: nil)
    ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call
    assert_equal 0, ResidentFallbackTurn.count
  end

  test "if the hop can no longer run when its job does, the room is told the subscription's refusal" do
    opt_in!
    ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call
    Setting.instance.update!(paid_fallback_enabled: false)
    assert_difference -> { @chat.messages.count }, 1 do
      perform_enqueued_jobs(only: ResidentFallbackHopJob)
    end
    assert_includes @chat.messages.order(:id).last.content, "subscription limit has been reached"
    assert_equal 1, @triggers.size
  end

  test "each lane keeps its own transcript cursor" do
    opt_in!
    base = "#{@agent.uuid}-#{@chat.id}"
    first = @chat.messages.order(:id).first
    later = @chat.messages.create!(role: "assistant", agent: @agent, content: "Later")
    AgentRuntimeInteraction.create!(agent: @agent, chat: @chat, trigger_kind: "conversation", session_id: base, conversation_obfuscated_id: @chat.to_param,
      requested_by: "souls.house", last_included_message_id: later.id, chaos_session_id: "p", transport_status: 200, runtime_status: "ok", started_at: 1.minute.ago, finished_at: 1.minute.ago)
    AgentRuntimeInteraction.create!(agent: @agent, chat: @chat, trigger_kind: "conversation", session_id: "#{base}-fallback", conversation_obfuscated_id: @chat.to_param,
      requested_by: "souls.house", last_included_message_id: first.id, chaos_session_id: "f", transport_status: 200, runtime_status: "ok", started_at: 1.minute.ago, finished_at: 1.minute.ago)
    primary = ExternalAgentResponseRequest.new(agent: @agent, chat: @chat)
    assert_equal later.id, primary.send(:prior_cursor_message_id)
    turn = ResidentFallbackTurn.create!(agent: @agent, chat: @chat, primary_provider: "xai", primary_model: "x", fallback_model_id: "anthropic/claude-sonnet-5", upstream_model: "anthropic/claude-sonnet-5")
    fallback = ExternalAgentResponseRequest.new(agent: @agent, chat: @chat, fallback_turn: turn)
    assert_equal first.id, fallback.send(:prior_cursor_message_id)
  end

  test "a fresh start owed in the room reaches both lanes through the shared generation" do
    chat_agent = ChatAgent.find_by!(agent: @agent, chat: @chat)
    request = ExternalAgentResponseRequest.new(agent: @agent, chat: @chat)
    assert_nil request.send(:trigger_payload)[:runtime_session_generation], "0 is the runtime's default; nothing is sent"

    SafeguardRoll.request_reset!(chat_agent)
    snapshot = SafeguardRoll.snapshot_for(agent: @agent, chat: @chat)
    assert_equal 1, snapshot.freshness_generation
    rolled = ExternalAgentResponseRequest.new(agent: @agent, chat: @chat)
    rolled.instance_variable_set(:@safeguard_roll, snapshot)
    assert_equal [ true, 1 ], rolled.send(:trigger_payload).values_at(:roll_session, :runtime_session_generation)

    # Not confirmed fresh: nothing moves.
    SafeguardRoll.acknowledge_conversation!(snapshot.completion_context, { status: 200, body: { "status" => "ok" } })
    assert_equal 0, chat_agent.reload.runtime_freshness_generation
    SafeguardRoll.acknowledge_conversation!(snapshot.completion_context,
      { status: 200, body: { "status" => "ok", "telemetry" => { "session" => { "outcome" => "rolled" } } } })
    assert_equal 1, chat_agent.reload.runtime_freshness_generation

    # The other lane, which recorded 0, is now sent 1 and rolls.
    turn = ResidentFallbackTurn.create!(agent: @agent, chat: @chat, primary_provider: "xai", primary_model: "x", fallback_model_id: "anthropic/claude-sonnet-5", upstream_model: "anthropic/claude-sonnet-5")
    assert_equal 1, ExternalAgentResponseRequest.new(agent: @agent, chat: @chat, fallback_turn: turn).send(:trigger_payload)[:runtime_session_generation]
  end

end
