require "test_helper"

class Agents::FallbackPoliciesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @account = accounts(:team_account)
    @agent = agents(:other_account_agent)
    Setting.instance.update!(allow_agents: true)
  end

  test "shows the fallback as off by default" do
    sign_in(users(:user_1))
    get account_agent_fallback_policy_path(@account, @agent), as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal false, body["enabled"]
    assert_equal "fallback_off", body["status"]
    assert_equal ResidentFallback::Models::ELIGIBLE.keys, body["model_choices"].pluck("model_id")
  end

  test "the owner turns it on, recorded and audited" do
    sign_in(users(:user_1))
    patch account_agent_fallback_policy_path(@account, @agent),
      params: { fallback_policy: { enabled: true, model_id: "anthropic/claude-sonnet-5", cap_usd: "12.50", cap_period: "week" } },
      as: :json

    assert_response :success
    policy = @agent.reload.fallback_policy
    assert policy.enabled?
    assert_equal users(:user_1), policy.enabled_by_user
    assert_not_nil policy.enabled_at
    assert_equal BigDecimal("12.5"), policy.cap_usd
    audit = AuditLog.where(action: "update_resident_fallback", auditable: @agent).last
    assert_equal true, audit.data["enabled"]
  end

  test "turning it on again clears the first-use notice, so the owner is told again" do
    sign_in(users(:user_1))
    policy = ResidentFallbackPolicy.create!(agent: @agent, enabled: true, model_id: "anthropic/claude-sonnet-5", cap_usd: 5,
      enabled_by_user: users(:user_1), enabled_at: 1.day.ago, use_notice_at: 1.hour.ago,
      use_notice_period_start: Time.current.utc.beginning_of_week(:monday))
    patch account_agent_fallback_policy_path(@account, @agent), params: { fallback_policy: { cap_usd: "6" } }, as: :json
    assert_not_nil policy.reload.use_notice_at, "an edit while on keeps the notice sent"
    assert_not_nil policy.use_notice_period_start

    patch account_agent_fallback_policy_path(@account, @agent), params: { fallback_policy: { enabled: false } }, as: :json
    patch account_agent_fallback_policy_path(@account, @agent), params: { fallback_policy: { enabled: true } }, as: :json
    assert_response :success
    assert_nil policy.reload.use_notice_at
    assert_nil policy.use_notice_period_start
    assert_nil response.parsed_body["use_notice_at"]
  end

  test "the card learns whether the house has the feature on" do
    sign_in(users(:user_1))
    Setting.instance.update!(paid_fallback_enabled: false)
    get account_agent_fallback_policy_path(@account, @agent), as: :json
    assert_equal false, response.parsed_body["available"]
    assert_equal account_agent_api_keys_path(@account), response.parsed_body["api_keys_url"]

    Setting.instance.update!(paid_fallback_enabled: true)
    get account_agent_fallback_policy_path(@account, @agent), as: :json
    assert_equal true, response.parsed_body["available"]
  end

  test "a member who isn't the owner can't change it" do
    sign_in(users(:existing_user))
    patch account_agent_fallback_policy_path(@account, @agent),
      params: { fallback_policy: { enabled: true, model_id: "anthropic/claude-sonnet-5", cap_usd: "5" } },
      as: :json

    assert_nil @agent.reload.fallback_policy
  end

  test "turning on without a cap is refused with a readable reason" do
    sign_in(users(:user_1))
    patch account_agent_fallback_policy_path(@account, @agent),
      params: { fallback_policy: { enabled: true, model_id: "anthropic/claude-sonnet-5" } },
      as: :json

    assert_response :unprocessable_entity
    assert_match "Cap usd must be set", response.parsed_body["error"]
    assert_not @agent.reload.fallback_policy&.enabled?
  end

end
