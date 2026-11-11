require "test_helper"

class ResidentFallbackMailerTest < ActionMailer::TestCase

  setup do
    @agent = agents(:research_assistant)
    @owner = @agent.account.owner
    ResidentFallbackPolicy.create!(agent: @agent, enabled: true, model_id: "anthropic/claude-opus-5.5", cap_usd: 25,
      cap_period: "week", enabled_by_user: @owner, enabled_at: Time.current)
    @chat = @agent.account.chats.create!(model_id: "x-ai/grok-build-0.1", title: "Fallback")
    @turn = ResidentFallbackTurn.create!(agent: @agent, chat: @chat, primary_provider: "xai", primary_model: "grok-build-0.1",
      fallback_model_id: "anthropic/claude-opus-5.5", upstream_model: "anthropic/claude-opus-5.5")
  end

  test "the first-use notice says which model, who pays, the cap, and where to turn it off" do
    mail = ResidentFallbackMailer.first_use(@turn)
    text = mail.text_part.body.to_s

    assert_equal [ @owner.email_address ], mail.to
    assert_equal "#{@agent.name} is answering on your paid fallback", mail.subject
    assert_includes text, "Model: Claude Opus 5.5, through OpenRouter."
    assert_includes text, "this account's own OpenRouter key"
    assert_includes text, "Cap: $25.00 a week."
    assert_includes text, "tab=settings"
    assert_includes text, "/chats/#{@chat.to_param}"
    assert_includes mail.html_part.body.to_s, "Claude Opus 5.5"
  end

end
