require "test_helper"

class Admin::AccountUsageReportTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @now = Time.utc(2026, 9, 5, 12)
  end

  test "counts account conversations once and agent participation separately" do
    other_agent = agents(:code_reviewer)
    chat = @account.chats.create!(title: "Shared chat", agent_ids: [ @agent.id, other_agent.id ])
    chat.messages.create!(role: "user", content: "Private message contents")
    accounts(:team_account).chats.create!(title: "Other account private title")

    report = Admin::AccountUsageReport.new(@account, now: @now).call
    assert_equal 1, report[:summary][:conversations]
    assert_equal 1, report[:agents].find { |agent| agent[:id] == @agent.to_param }[:conversations]
    assert_equal 1, report[:agents].find { |agent| agent[:id] == other_agent.to_param }[:conversations]
    assert_equal 1, report[:recent_conversations].first[:messages]
    assert_not_includes report.to_json, "Other account private title"
    assert_not_includes report.to_json, "Private message contents"
    assert_not_includes report.to_json, @agent.system_prompt
  end

  test "groups logical sessions per agent and excludes busy retries without losing unreported statuses" do
    record(@agent, "shared", @now - 1.day)
    record(@agent, "shared", @now - 1.hour)
    record(agents(:code_reviewer), "shared", @now - 2.hours)
    record(@agent, nil, @now - 3.hours)
    record(@agent, "busy", @now, transport_status: 409, runtime_status: "already_running")
    record(agents(:other_account_agent), "other-account", @now)

    report = Admin::AccountUsageReport.new(@account, now: @now).call
    assert_equal 3, report[:summary][:sessions]
    assert_equal 5, report[:summary][:runs]
    assert_equal 30, report[:activity].size
    assert_equal 3, report[:activity].last[:sessions]
    assert_equal 4, report[:activity].last[:runs]
    assert_equal 1, report[:activity][-2][:sessions]
    assert_equal 0, report[:activity].first[:runs]
    assert_equal 2, report[:recent_sessions].first[:runs]
    assert_equal @agent.to_param, report[:recent_sessions].first[:agent_id]
    assert_not_includes report.to_json, "other-account"
    assert_not_includes report.to_json, "secret runtime output"
  end

  test "recent lists are bounded and ordered by activity" do
    12.times do |index|
      record(@agent, "session-#{index}", @now - index.hours)
      @account.chats.create!(title: "Chat #{index}", updated_at: @now - index.hours)
    end
    report = Admin::AccountUsageReport.new(@account, now: @now).call
    assert_equal 10, report[:recent_sessions].size
    assert_equal "session-0", report[:recent_sessions].first[:session_id]
    assert_equal 10, report[:recent_conversations].size
    assert_equal "Chat 0", report[:recent_conversations].first[:title]
  end

  test "empty account has zero counts and a zero filled chart" do
    account = Account.create!(name: "Unused", account_type: :team)
    report = Admin::AccountUsageReport.new(account, now: @now).call
    assert_equal 0, report[:summary][:sessions]
    assert_equal [], report[:agents]
    assert_equal [], report[:recent_conversations]
    assert_equal [], report[:recent_sessions]
    assert report[:activity].all? { |day| day[:runs].zero? && day[:sessions].zero? }
  end

  test "integration metadata is allowlisted and includes disabled grants" do
    connection = @account.service_connections.create!(
      provider: "oura", connected_by_user: @account.owner,
      credential_kind: "oauth", label: "Personal Oura", status: "suspended",
      credential_payload: '{"access_token":"integration-secret"}'
    )
    connection.agent_service_accesses.create!(agent: @agent, enabled: false)
    @account.update!(openai_api_key: "account-key-secret")
    @agent.update_columns(provider_connections: { "anthropic" => { "status" => "connected", "token" => "provider-secret" } })

    report = Admin::AccountUsageReport.new(@account, now: @now).call
    service = report[:integrations].find { |item| item[:label] == "Personal Oura" }
    assert_equal "suspended", service[:status]
    assert_empty service[:agents]
    agent = report[:agents].find { |item| item[:id] == @agent.to_param }
    assert_equal false, agent[:services].first[:enabled]
    assert_equal true, report[:ai_providers].find { |item| item[:provider] == :openai }[:configured]
    %w[integration-secret account-key-secret provider-secret credential_payload].each do |secret|
      assert_not_includes report.to_json, secret
    end
  end

  test "reports legacy integrations without duplicating migrated Oura connections" do
    legacy = OuraIntegration.create!(user: @account.owner, enabled: false)
    @account.update!(github_pat: "github-secret")
    report = Admin::AccountUsageReport.new(@account, now: @now).call
    assert_equal "disabled", report[:integrations].find { |row| row[:provider] == "oura" }[:status]
    assert report[:integrations].any? { |row| row[:label] == "GitHub repository access" }
    assert_not_includes report.to_json, "github-secret"

    @account.service_connections.create!(
      provider: "oura", connected_by_user: @account.owner, credential_kind: "oauth",
      legacy_oura_integration: legacy, credential_payload: '{"access_token":"secret"}'
    )
    report = Admin::AccountUsageReport.new(@account, now: @now).call
    assert_equal 1, report[:integrations].count { |row| row[:provider] == "oura" }
  end

  test "chart includes UTC midnight and excludes activity outside its window" do
    record(@agent, "start", Time.utc(2026, 8, 7))
    record(@agent, "before", Time.utc(2026, 8, 7) - 1.second)
    record(@agent, "future", @now + 1.second)
    report = Admin::AccountUsageReport.new(@account, now: @now).call
    assert_equal "2026-08-07", report[:activity].first[:date]
    assert_equal 1, report[:activity].sum { |day| day[:runs] }
  end

  test "includes resident identity and current model OAuth mode rather than unrelated subscriptions" do
    @agent.update_columns(
      runtime: "external", model_id: "anthropic/claude-opus-4", icon: "Moon", colour: "violet",
      provider_auth_modes: { "anthropic" => "oauth_account", "openai" => "oauth_account" },
      provider_connections: { "anthropic" => { "status" => "connected", "email" => "private@example.com" } }
    )
    resident = resident_report
    assert_equal "Moon", resident[:icon]
    assert_equal "violet", resident[:colour]
    assert_equal({ provider: "anthropic", mode: "oauth_account", connection_status: "connected" }, resident[:model_access])
    assert_not_includes resident[:model_access].to_json, "private@example.com"
  end

  test "shows OpenRouter API routing even when another provider has an OAuth connection" do
    @agent.update_columns(
      runtime: "external", model_id: "anthropic/claude-opus-4",
      provider_auth_modes: { "openai" => "oauth_account" }
    )
    RubyLLM.config.stub(:anthropic_api_key, nil) do
      assert_equal({ provider: "openrouter", mode: "api_key", connection_status: nil }, resident_report[:model_access])
    end
  end

  test "deprecated inline residents use API even with old subscription settings" do
    @agent.update_columns(
      runtime: "inline", model_id: "anthropic/claude-opus-4",
      provider_auth_modes: { "anthropic" => "oauth_account" }
    )
    @account.update!(anthropic_api_key: "account-test-key")
    assert_equal({ provider: "anthropic", mode: "api_key", connection_status: nil }, resident_report[:model_access])
  end

  private

  def resident_report
    Admin::AccountUsageReport.new(@account, now: @now).call[:agents].find { |row| row[:id] == @agent.to_param }
  end

  def record(agent, session_id, started_at, **attributes)
    AgentRuntimeInteraction.create!(
      agent: agent, session_id: session_id, started_at: started_at,
      trigger_kind: "wake", stdout: "secret runtime output", **attributes
    )
  end

end
