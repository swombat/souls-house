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
