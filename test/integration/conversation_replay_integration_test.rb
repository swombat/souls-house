require "test_helper"
require "support/vcr_setup"

# Integration tests for the upgraded conversational-replay flow.
#
# These tests assert end-to-end persistence shape on Message rows after
# real provider calls. Cassettes need to be recorded against live APIs the
# first time. Run with VCR record mode set to :new_episodes (default) and
# valid credentials configured.
#
# Cassettes used (record by deleting the file under test/vcr_cassettes/conversation_replay/):
#   - anthropic_thinking_two_turn
#   - multi_agent_isolation
#   - openrouter_no_signature_thinking
#   - gemini_tool_call_continuity
#   - legacy_anthropic_no_signature_recovers
#   - gemini_legacy_tool_continuity_missing
class ConversationReplayIntegrationTest < ActiveSupport::TestCase

  setup do
    @user = User.find_or_create_by!(email_address: "replay-integration@example.com") { |u| u.password = "password123" }
    @user.profile.update!(first_name: "Replay", last_name: "User")
    @account = @user.personal_account
    @account.update!(use_system_ai_credentials: true)
  end

  test "anthropic_thinking_two_turn — thinking persists across turns" do
    skip_unless_cassette("anthropic_thinking_two_turn")

    opus = @account.agents.create!(
      name: "Opus",
      model_id: "anthropic/claude-opus-4.5",
      system_prompt: "You are Opus. Keep replies under 30 words.",
      thinking_enabled: true,
      thinking_budget: 5000
    )

    chat = @account.chats.new(model_id: "anthropic/claude-opus-4.5", manual_responses: true, title: "Two-Turn Thinking")
    chat.agents = [ opus ]
    chat.save!

    chat.messages.create!(role: "user", user: @user, content: "What is 7 times 8?")

    VCR.use_cassette("conversation_replay/anthropic_thinking_two_turn", match_requests_on: [ :method, :uri ]) do
      ManualAgentResponseJob.perform_now(chat, opus)
    end

    first_reply = chat.messages.where(role: "assistant", agent: opus).order(:created_at).last
    assert_not_nil first_reply
    assert first_reply.thinking_text.present?, "First turn should carry thinking text"
    assert first_reply.thinking_signature.present?, "First turn should carry a stored thinking signature"
    assert_equal "anthropic", first_reply.replay_payload["provider"]

    chat.messages.create!(role: "user", user: @user, content: "Now multiply that by 2.")

    VCR.use_cassette("conversation_replay/anthropic_thinking_two_turn_2", match_requests_on: [ :method, :uri ]) do
      ManualAgentResponseJob.perform_now(chat, opus)
    end

    second_reply = chat.messages.where(role: "assistant", agent: opus).order(:created_at).last
    assert_not_nil second_reply
    refute_equal first_reply.id, second_reply.id
    assert second_reply.thinking_signature.present?, "Second turn should still get a signed thinking block"
    assert_nil second_reply.reasoning_skip_reason
  end

  test "multi_agent_isolation — one agent missing reasoning does not disable another" do
    skip_unless_cassette("multi_agent_isolation")

    opus = @account.agents.create!(name: "Opus", model_id: "anthropic/claude-opus-4.5", system_prompt: "Be brief.", thinking_enabled: true, thinking_budget: 5000)
    grok = @account.agents.create!(name: "Grok", model_id: "x-ai/grok-4", system_prompt: "Be brief.", thinking_enabled: false)

    chat = @account.chats.new(model_id: "anthropic/claude-opus-4.5", manual_responses: true, title: "Mixed Agents")
    chat.agents = [ opus, grok ]
    chat.save!

    chat.messages.create!(role: "user", user: @user, content: "Both of you, in one sentence, name a colour.")

    VCR.use_cassette("conversation_replay/multi_agent_isolation", match_requests_on: [ :method, :uri ]) do
      ManualAgentResponseJob.perform_now(chat, grok)
      ManualAgentResponseJob.perform_now(chat, opus)
    end

    opus_reply = chat.messages.where(role: "assistant", agent: opus).order(:created_at).last
    assert opus_reply.thinking_signature.present?, "Opus's thinking should be enabled despite Grok's thinking-less reply"
    assert_nil opus_reply.reasoning_skip_reason
  end

  test "openrouter_no_signature_thinking — OpenRouter reasoning_details persist and replay" do
    skip_unless_cassette("openrouter_no_signature_thinking")

    grok = @account.agents.create!(
      name: "GrokFast",
      model_id: "x-ai/grok-4-fast",
      system_prompt: "Reply in one short sentence.",
      thinking_enabled: true,
      thinking_budget: 2000
    )

    chat = @account.chats.new(model_id: "x-ai/grok-4-fast", manual_responses: true, title: "OpenRouter Reasoning")
    chat.agents = [ grok ]
    chat.save!

    chat.messages.create!(role: "user", user: @user, content: "What is the boiling point of water in Celsius?")

    VCR.use_cassette("conversation_replay/openrouter_no_signature_thinking", match_requests_on: [ :method, :uri ]) do
      ManualAgentResponseJob.perform_now(chat, grok)
    end

    reply = chat.messages.where(role: "assistant", agent: grok).order(:created_at).last
    assert_not_nil reply
    assert_nil reply.reasoning_skip_reason, "OpenRouter replies should NOT be flagged legacy_no_signature"
  end

  test "gemini_tool_call_continuity — Gemini tool_calls.replay_payload carries thought_signature" do
    skip_unless_cassette("gemini_tool_call_continuity")

    gem = @account.agents.create!(
      name: "Gem",
      model_id: "google/gemini-3-pro-preview",
      system_prompt: "Use the web tool when asked.",
      thinking_enabled: true,
      thinking_budget: 4000
    )
    # The cassette preserves a response recorded when WebTool still existed.
    # It tests replay persistence, not the retired tool's availability.

    chat = @account.chats.new(model_id: "google/gemini-3-pro-preview", manual_responses: true, title: "Gemini Tool Continuity", web_access: true)
    chat.agents = [ gem ]
    chat.save!

    chat.messages.create!(role: "user", user: @user, content: "Fetch https://example.com and tell me the title in one phrase.")

    VCR.use_cassette("conversation_replay/gemini_tool_call_continuity", match_requests_on: [ :method, :uri ]) do
      ManualAgentResponseJob.perform_now(chat, gem)
    end

    last = chat.messages.where(role: "assistant", agent: gem).order(:created_at).last
    assert_not_nil last
    assert last.tool_calls.any?, "Gemini turn should produce stored tool_calls"
    signed = last.tool_calls.detect { |tc| tc.replay_payload&.dig("thought_signature").present? }
    assert_not_nil signed, "At least one tool_call should carry a thought_signature in replay_payload"
  end

  test "legacy_anthropic_no_signature_recovers — legacy turn replays as plain text; new turn restores thinking" do
    skip_unless_cassette("legacy_anthropic_no_signature_recovers")

    opus = @account.agents.create!(name: "Opus", model_id: "anthropic/claude-opus-4.5", system_prompt: "Be brief.", thinking_enabled: true, thinking_budget: 4000)
    chat = @account.chats.new(model_id: "anthropic/claude-opus-4.5", manual_responses: true, title: "Legacy Recover")
    chat.agents = [ opus ]
    chat.save!

    chat.messages.create!(role: "user", user: @user, content: "Hello.")
    legacy_reply = chat.messages.create!(
      role: "assistant", agent: opus,
      content: "Hello! I'm a legacy reply.",
      thinking: "Legacy unsigned thinking text."
    )
    assert_equal "legacy_no_signature", legacy_reply.reasoning_skip_reason

    chat.messages.create!(role: "user", user: @user, content: "What's the capital of France?")

    VCR.use_cassette("conversation_replay/legacy_anthropic_no_signature_recovers", match_requests_on: [ :method, :uri ]) do
      ManualAgentResponseJob.perform_now(chat, opus)
    end

    new_reply = chat.messages.where(role: "assistant", agent: opus).order(:created_at).last
    refute_equal legacy_reply.id, new_reply.id
    assert new_reply.thinking_signature.present?, "New turn should carry a fresh thinking signature"
    assert_nil new_reply.reasoning_skip_reason
  end

  test "gemini_legacy_tool_continuity_missing — replay omits missing signature; reasoning_skip_reason stamped" do
    skip_unless_cassette("gemini_legacy_tool_continuity_missing")

    gem = @account.agents.create!(name: "Gem", model_id: "google/gemini-3-pro-preview", system_prompt: "Be brief.", thinking_enabled: true, thinking_budget: 4000)
    # The stored legacy tool call below remains valid replay history even though
    # new agents can no longer enable WebTool.
    chat = @account.chats.new(model_id: "google/gemini-3-pro-preview", manual_responses: true, title: "Gemini Legacy", web_access: true)
    chat.agents = [ gem ]
    chat.save!

    chat.messages.create!(role: "user", user: @user, content: "Fetch a page (legacy turn).")
    legacy_msg = chat.messages.create!(role: "assistant", agent: gem, content: "Used tool (legacy).")
    legacy_msg.tool_calls.create!(tool_call_id: "legacy-tc-1", name: "WebTool", arguments: { url: "https://example.com" }, replay_payload: nil)

    chat.messages.create!(role: "user", user: @user, content: "Now follow up.")

    VCR.use_cassette("conversation_replay/gemini_legacy_tool_continuity_missing", match_requests_on: [ :method, :uri ]) do
      ManualAgentResponseJob.perform_now(chat, gem)
    end

    new_reply = chat.messages.where(role: "assistant", agent: gem).order(:created_at).last
    assert_equal "tool_continuity_missing", new_reply.reasoning_skip_reason

    legacy_replay = legacy_msg.replay_for(:gemini, current_agent: gem)
    legacy_tc = legacy_replay[:tool_calls]["legacy-tc-1"]
    assert_nil legacy_tc.thought_signature,
      "Legacy tool call should replay without a fabricated thought_signature"
  end

  private

  # Skip a cassette-backed integration test if its cassette has not yet been recorded.
  # Set RECORD_CASSETTES=1 to bypass the skip and record cassettes live against real APIs.
  def skip_unless_cassette(name)
    return if ENV["RECORD_CASSETTES"]
    cassette_dir = Rails.root.join("test/vcr_cassettes/conversation_replay")
    matching = Dir.glob(cassette_dir.join("#{name}*.yml"))
    skip("Cassette #{name}.yml not yet recorded — needs live API run") if matching.empty?
  end

end
