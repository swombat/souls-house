require "test_helper"
require "webmock/minitest"

class ExternalAgentOrientationRequestTest < ActiveSupport::TestCase

  test "orientation request invites first wake and records oriented_at when journal grows" do
    agent = agents(:research_assistant)
    agent.update!(model_id: "anthropic/claude-opus-4.7", provider_auth_modes: { "anthropic" => "oauth_account" })
    agent.update!(
      runtime: "external",
      uuid: SecureRandom.uuid_v7,
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid",
      health_state: "healthy",
      consecutive_health_failures: 0,
      turn_timeout_minutes: 180
    )
    fake_journal_status = Object.new
    def fake_journal_status.snapshot = { "2026-05-28.md" => 100 }
    def fake_journal_status.grown_since?(_before) = true

    stub_request(:post, "https://agent.example.com/trigger")
      .with do |request|
        body = JSON.parse(request.body)
        body.fetch("trigger_kind") == "orientation" &&
          body.fetch("model") == "claude-opus-4-7" &&
          body.fetch("timeout_secs") == 10800
      end
      .to_return(status: 200, body: { status: "ok", stdout: "oriented" }.to_json)

    Agents::DailyJournalStatus.stub :new, fake_journal_status do
      result = ExternalAgentOrientationRequest.new(agent: agent, requested_by: "test").call

      assert_equal 200, result[:status]
      assert_equal true, result[:oriented]
      assert_not_nil agent.reload.oriented_at
    end

    interaction = AgentRuntimeInteraction.last
    assert_equal "orientation", interaction.trigger_kind
    assert_includes interaction.request_text, "orientation wake"
    assert_includes interaction.request_text, "first daily-journal entry"
    assert_includes interaction.request_text, "helixkit-append-journal"
    assert_includes interaction.request_text, "/usr/local/share/helixkit-agent/helixkit-api.md"
  end

  test "orientation does not mark oriented when no journal grows" do
    agent = agents(:research_assistant)
    agent.update!(
      runtime: "external",
      uuid: SecureRandom.uuid_v7,
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid",
      health_state: "healthy",
      consecutive_health_failures: 0
    )
    fake_journal_status = Object.new
    def fake_journal_status.snapshot = {}
    def fake_journal_status.grown_since?(_before) = false

    stub_request(:post, "https://agent.example.com/trigger")
      .to_return(status: 200, body: { status: "ok" }.to_json)

    Agents::DailyJournalStatus.stub :new, fake_journal_status do
      result = ExternalAgentOrientationRequest.new(agent: agent, requested_by: "test").call

      assert_equal 200, result[:status]
      assert_equal false, result[:oriented]
      assert_nil agent.reload.oriented_at
    end
  end

  test "model change orientation has its own framing and includes active notices" do
    agent = agents(:research_assistant)
    Notice.create!(
      scope: "account",
      account: agent.account,
      notice_type: "announcement",
      body: "Orientation notice",
      expires_at: 1.day.from_now
    )
    request = ExternalAgentOrientationRequest.new(agent: agent, context: :model_change)
    text = request.send(:request_text)

    assert_includes text, "Orientation notice"
    assert_includes text, "Your configured model has changed"
    assert_includes text, "fresh orientation wake"
    assert_includes text, "Nothing needs to be performed"
    refute_includes text, "migrated from HelixKit"
    refute_includes text, "first wake"
  end

end
