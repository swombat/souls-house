require "test_helper"

class KimiCodeNoticeTest < ActiveSupport::TestCase

  test "key rejection explains Code versus PAYG without guessing what key was supplied" do
    text = KimiCodeNotice.text("auth_expired")
    assert_includes text, "Code Console"
    assert_includes text, "PAYG"
    assert_not_includes text, "Reconnect"
    assert_nil KimiCodeNotice.text("private-provider-error")
  end

  test "queued completion surfaces actionable guidance for API-key subscription auth" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", manual_responses: true, agents: [ agent ])
    interaction = AgentRuntimeInteraction.new(agent: agent, chat: chat,
      provider: "kimi", provider_auth_mode: "api_key")
    turn = Struct.new(:agent, :agent_runtime_interaction).new(agent, interaction)
    completion = ResidentTurnCompletion.new(turn, { "body" => { "error_kind" => "auth_expired", "error" => "PRIVATE ECHO" } })
    assert_difference -> { chat.messages.count }, 1 do
      completion.send(:surface_provider_failure, {})
    end
    assert_includes chat.messages.order(:id).last.content, "Kimi Code Console"
    assert_not_includes chat.messages.order(:id).last.content, "PRIVATE ECHO"
  end

end
