require "test_helper"
require "webmock/minitest"

class ResidentFallback::HopTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

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

  test "a pre-dispatch refusal sends the same run again on the fallback lane, and the run's result is the fallback's" do
    opt_in!
    assert_no_difference -> { @chat.messages.count } do
      ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call
    end
    turn = ResidentFallbackTurn.sole
    run = turn.fallback_interaction
    assert_equal run, turn.primary_interaction, "one logical turn, one run"
    assert_equal [ "xai", "grok-build-0.1", "anthropic/claude-sonnet-5" ], [ turn.primary_provider, turn.primary_model, turn.fallback_model_id ]
    assert_equal Time.utc(2026, 11, 11, 14), turn.primary_resets_at
    assert_equal 429, turn.primary_result["status"]

    assert_equal 2, @triggers.size
    first, hop = @triggers
    assert_equal [ "xai", "oauth_account", "#{@agent.uuid}-#{@chat.id}" ], first.values_at("provider", "auth_mode", "session_id")
    assert_equal [ "house", "fallback/anthropic/claude-sonnet-5", "api_key", true ], hop.values_at("provider", "model", "auth_mode", "paid_fallback")
    assert_equal "#{@agent.uuid}-#{@chat.id}-fallback", hop["session_id"]
    assert_nil hop["reasoning_effort"]
    assert_includes hop["request"], "Paid fallback: your subscription's allowance ran out"
    assert_equal run.id.to_s, hop["inference_run"]
    run.reload
    assert_equal [ "house", "#{@agent.uuid}-#{@chat.id}-fallback", 200, "ok" ], [ run.provider, run.session_id, run.transport_status, run.runtime_status ]
    assert_equal 1, @chat.agent_runtime_interactions.count
  end

  test "the reply carries the label from its own run, and the owner is told once on first use" do
    policy = opt_in!
    assert_enqueued_emails 1 do
      ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call
    end
    run = ResidentFallbackTurn.sole.fallback_interaction
    assert_not_nil policy.reload.first_used_at

    reply = @chat.messages.create!(role: "assistant", agent: @agent, content: "On the fallback.", runtime_interaction: run)
    label = reply.paid_fallback
    assert_equal [ "Claude Sonnet 5", "OpenRouter", "paid by this account's OpenRouter key" ],
      label.values_at(:model_label, :provider_label, :payer_label)
    assert_equal "Claude Sonnet 5", reply.runtime_model_label
    assert_equal label.stringify_keys, JSON.parse(reply.as_json.to_json)["paid_fallback"]

    # Changing the policy afterwards doesn't relabel the answer.
    policy.update!(model_id: "anthropic/claude-opus-5.5")
    assert_equal "Claude Sonnet 5", reply.reload.paid_fallback[:model_label]

    # A second hop, in another conversation, sends no second email.
    other = @agent.account.chats.create!(model_id: "x-ai/grok-build-0.1", title: "Fallback 2")
    other.messages.create!(role: "user", user: users(:user_1), content: "Hello again")
    other.agents << @agent
    other.update!(manual_responses: true)
    assert_no_enqueued_emails do
      ExternalAgentResponseRequest.new(agent: @agent, chat: other).call
    end
    assert_equal 2, ResidentFallbackTurn.count

    # A reply on the subscription carries no label.
    plain = @chat.messages.create!(role: "assistant", agent: @agent, content: "On the plan.",
      runtime_interaction: AgentRuntimeInteraction.create!(agent: @agent, chat: @chat, trigger_kind: "conversation",
        provider: "xai", model: "grok-build-0.1", started_at: Time.current))
    assert_nil plain.paid_fallback
  end

  test "asynchronous: the refused turn is retired as hopped and the same run gets a fallback turn" do
    opt_in!
    sandbox = Object.new
    sandbox.define_singleton_method(:with_runtime) { |&block| block.call }
    ResidentTurn.stub(:enabled?, true) do
      Agents::Sandbox.stub(:new, sandbox) do
        assert_equal 202, ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call[:status]
        run = @chat.agent_runtime_interactions.sole
        first = run.resident_turn
        first.finish!({ "status" => 429, "body" => LIMITED.deep_stringify_keys })
        assert first.reload.hopped_at
        assert_nil run.reload.finished_at, "the run stays open for its fallback"
        assert_nil run.resident_turn

        perform_enqueued_jobs(only: ResidentFallbackHopJob)
        # A second delivery of the same job does nothing (Mira #887).
        ResidentFallbackHopJob.perform_now(ResidentFallbackTurn.sole.id)
        assert_equal 1, ResidentTurn.where(agent_runtime_interaction_id: run.id, hopped_at: nil).count
        assert_nil run.reload.finished_at
        second = run.reload.resident_turn
        payload = JSON.parse(second.payload)
        assert_equal [ "house", "fallback/anthropic/claude-sonnet-5", true ], payload.values_at("provider", "model", "paid_fallback")
        assert_equal "#{@agent.uuid}-#{@chat.id}-fallback", second.session_id
        assert_equal [ first.id ], run.hopped_resident_turns.pluck(:id)

        second.finish!({ "status" => 200, "body" => { "status" => "ok", "returncode" => 0 } })
        assert_equal [ 200, "ok" ], run.reload.values_at(:transport_status, :runtime_status)
        assert run.finished_at
      end
    end
    assert_no_match(/subscription limit/, @chat.messages.order(:id).last.content)
    assert_not_requested :post, "https://agent.example.com/trigger"
  end

  test "asynchronous: a source withdrawn before the fallback dispatch ends the run with the subscription's refusal" do
    opt_in!
    sandbox = Object.new
    sandbox.define_singleton_method(:with_runtime) { |&block| block.call }
    ResidentTurn.stub(:enabled?, true) do
      Agents::Sandbox.stub(:new, sandbox) do
        ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call
        run = @chat.agent_runtime_interactions.sole
        run.resident_turn.finish!({ "status" => 429, "body" => LIMITED.deep_stringify_keys })
        # The owner pauses the resident before the fallback dispatch.
        @agent.update!(paused: true)
        assert_difference -> { @chat.messages.count }, 1 do
          perform_enqueued_jobs(only: ResidentFallbackHopJob)
        end
        assert_equal [ 429, "xai" ], run.reload.values_at(:transport_status, :provider)
        assert run.finished_at
        assert_nil run.resident_turn
      end
    end
    assert_includes @chat.messages.order(:id).last.content, "subscription limit has been reached"
  end

  test "a source that would no longer start the run keeps the hop from opening" do
    opt_in!
    run = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat)
    run.update!(provider_auth_mode: "oauth_account", provider: "xai", model: "grok-build-0.1", session_id: "#{@agent.uuid}-#{@chat.id}")
    dispatch = Object.new
    dispatch.define_singleton_method(:with_lock) { |&block| block.call }
    dispatch.define_singleton_method(:source_invalid_reason) { "discarded" }
    run.stub(:message_dispatch, dispatch) do
      assert_equal "message_dispatch:discarded", ResidentFallback::Hop.source_refusal(run)
      assert_nil ResidentFallback::Hop.open!(interaction: run, result: { status: 429, body: LIMITED.deep_stringify_keys })
    end
    assert_nil ResidentFallback::Hop.source_refusal(run)
  end

  test "a commitment's cue rides the fallback dispatch even when it is outside the transcript" do
    opt_in!
    run = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat)
    commitment = Commitment.create!(agent: @agent, source_chat: @chat, text: "Check the receipt for run 42795010627", due_at: 1.hour.from_now)
    commitment.update_columns(status: "activated", wake_state: "woken", wake_interaction_id: run.id)
    turn = ResidentFallbackTurn.create!(agent: @agent, chat: @chat, primary_interaction: run, fallback_interaction: run, primary_provider: "xai",
      primary_model: "grok-build-0.1", fallback_model_id: "anthropic/claude-sonnet-5", upstream_model: "anthropic/claude-sonnet-5")
    request = ExternalAgentResponseRequest.new(agent: @agent, chat: @chat, interaction: run, fallback_turn: turn)
    assert_includes request.send(:request_text), "Check the receipt for run 42795010627"
    assert_nil ResidentFallback::Hop.source_refusal(run)
    commitment.update_columns(status: "cancelled")
    assert_equal "commitment:commitment_cancelled", ResidentFallback::Hop.source_refusal(run)
  end

  test "a fallback dispatch never hops again, a refusal after the run started doesn't hop, and a run hops once" do
    opt_in!
    interaction = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat)
    interaction.update!(provider_auth_mode: "oauth_account", provider: "xai", model: "grok-build-0.1",
      session_id: "#{@agent.uuid}-#{@chat.id}-fallback")
    limited = { status: 429, body: LIMITED.deep_stringify_keys }
    assert_nil ResidentFallback::Hop.open!(interaction: interaction, result: limited)
    interaction.update!(session_id: "#{@agent.uuid}-#{@chat.id}")
    post_run = { status: 200, body: { "status" => "error", "error_kind" => "subscription_limit" } }
    assert_nil ResidentFallback::Hop.open!(interaction: interaction, result: post_run)
    assert ResidentFallback::Hop.open!(interaction: interaction, result: limited)
    assert_nil ResidentFallback::Hop.open!(interaction: interaction, result: limited), "one hop per run"
  end

  test "an imported home doesn't hop: its own Chaos configuration is outside the runtime's key guard" do
    opt_in!
    @agent.update_columns(home_profile: "portable_v1", portable_home_id: 1)
    assert @agent.reload.imported_home?
    ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call
    assert_equal 0, ResidentFallbackTurn.count
    assert_includes @chat.messages.order(:id).last.content, "subscription limit has been reached"
  end

  test "a policy that can't admit a call (no own key) doesn't hop" do
    opt_in!
    @agent.account.update_columns(openrouter_api_key: nil)
    ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call
    assert_equal 0, ResidentFallbackTurn.count
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

  test "P, F, P, F with messages arriving mid-run: each lane resumes from its own cursor and sees everything after it" do
    opt_in!
    @agent.update!(persistent_session: true)
    limited = true
    mid_run = nil
    WebMock.reset!
    @triggers = []
    stub_request(:post, "https://agent.example.com/trigger").to_return do |request|
      body = JSON.parse(request.body)
      @triggers << body
      if body["provider"] == "house"
        # A message lands while the fallback runs; its cursor was fixed before dispatch.
        mid_run = @chat.messages.create!(role: "assistant", agent: agents(:code_reviewer), content: "mid-run #{@triggers.size}")
        { status: 200, body: { status: "ok", returncode: 0, chaos_session_id: "f" }.to_json }
      elsif limited
        { status: 429, body: LIMITED.to_json }
      else
        { status: 200, body: { status: "ok", returncode: 0, chaos_session_id: "p" }.to_json }
      end
    end
    respond = -> { ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call }

    respond.call # P refused -> F (fresh: full transcript)
    f1 = @triggers.last
    assert_equal "#{@agent.uuid}-#{@chat.id}-fallback", f1["session_id"]
    assert_nil f1["request_delta"], "the fallback lane's first turn has no cursor"
    first_mid = mid_run

    limited = false
    respond.call # P runs: its own lane has no successful run yet, so the full transcript
    p1 = @triggers.last
    assert_equal "#{@agent.uuid}-#{@chat.id}", p1["session_id"]
    assert_nil p1["request_delta"]
    assert_includes p1["request"], "mid-run 2"

    @chat.messages.create!(role: "assistant", agent: agents(:code_reviewer), content: "between turns")
    limited = true
    respond.call # P refused -> F resumes from its own cursor
    f2 = @triggers.last
    assert_equal "#{@agent.uuid}-#{@chat.id}-fallback", f2["session_id"]
    assert_includes f2["request_delta"], "mid-run 2", "the message that arrived during F's first run"
    assert_includes f2["request_delta"], "between turns"
    assert_not_includes f2["request_delta"], "Hello\n", "nothing before F's cursor"

    limited = false
    respond.call # P resumes from its cursor: sees F's mid-run message and what followed
    p2 = @triggers.last
    assert_equal "#{@agent.uuid}-#{@chat.id}", p2["session_id"]
    assert_includes p2["request_delta"], "between turns"
    assert_includes p2["request_delta"], mid_run.content
    assert_not_equal first_mid.id, mid_run.id
  end

  test "a reset taken on the fallback lane reaches the subscription lane on its return, and neither lane resumes a pre-reset session" do
    opt_in!
    limited = false
    WebMock.reset!
    @triggers = []
    stub_request(:post, "https://agent.example.com/trigger").to_return do |request|
      body = JSON.parse(request.body)
      @triggers << body
      if body["provider"] != "house" && limited
        next { status: 429, body: LIMITED.to_json }
      end
      session = body["roll_session"] ? { outcome: "rolled" } : { outcome: "resumed" }
      { status: 200, body: { status: "ok", returncode: 0, chaos_session_id: "s#{@triggers.size}", telemetry: { session: session } }.to_json }
    end
    respond = -> { ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call }
    chat_agent = ChatAgent.find_by!(agent: @agent, chat: @chat)

    respond.call # P, before any reset: generation 0 (not sent)
    assert_nil @triggers.last["runtime_session_generation"]

    SafeguardRoll.request_reset!(chat_agent)
    limited = true
    respond.call # P refused, so F takes the reset
    p_refused, f = @triggers.last(2)
    assert_equal [ "xai", true, 1 ], p_refused.values_at("provider", "roll_session", "runtime_session_generation")
    assert_equal [ "house", true, 1 ], f.values_at("provider", "roll_session", "runtime_session_generation")
    assert_equal 1, chat_agent.reload.runtime_freshness_generation, "acknowledged on F's confirmed fresh start"
    assert_equal chat_agent.safeguard_reset_requested_generation, chat_agent.safeguard_reset_acknowledged_generation

    limited = false
    respond.call # back on P: no roll owed, but generation 1 against P's sidecar (0) makes the runtime roll it
    back = @triggers.last
    assert_equal [ "xai", nil, 1 ], back.values_at("provider", "roll_session", "runtime_session_generation")

    limited = true
    respond.call # and F again: same generation as its sidecar, so it resumes
    again = @triggers.last
    assert_equal [ "house", nil, 1 ], again.values_at("provider", "roll_session", "runtime_session_generation")
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
