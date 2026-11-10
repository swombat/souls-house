require "test_helper"

class ResidentFallback::DecisionTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:other_account_agent)
    @account = @agent.account
    # The team account falls back to house keys; the fallback must never.
    @account.update_columns(use_system_ai_credentials: true, openrouter_api_key: nil)
    @owner = users(:user_1)
    @now = Time.utc(2026, 11, 10, 12)
  end

  def enable!(cap: 10, period: "month", model: "anthropic/claude-sonnet-5")
    ResidentFallbackPolicy.create!(agent: @agent, enabled: true, model_id: model, cap_usd: cap, cap_period: period,
      enabled_by_user: @owner, enabled_at: @now)
  end

  test "off by default: no policy and a disabled policy both refuse nothing and admit nothing" do
    assert_predicate ResidentFallback::Decision.for(@agent, at: @now), :off?
    ResidentFallbackPolicy.create!(agent: @agent)
    decision = ResidentFallback::Decision.for(@agent.reload, at: @now)
    assert_predicate decision, :off?
    assert_not decision.refused?
    error = assert_raises(ResidentFallback::Decision::Refused) do
      ResidentFallback::Decision.admit_call!(@agent, input_bound_tokens: 1_000, max_output_tokens: 1_000, at: @now)
    end
    assert_equal "fallback_off", error.code
    assert_equal 0, ResidentFallbackCall.count
  end

  test "never pays with a house key: no own OpenRouter key is a readable refusal" do
    enable!
    Account.stub(:system_ai_api_key, "sk-or-house") do
      # The house key is what Account#ai_api_key would hand out here.
      assert_equal "sk-or-house", @account.reload.ai_api_key(:openrouter)
      decision = ResidentFallback::Decision.for(@agent.reload, at: @now)
      assert_equal "fallback_payer_key_missing", decision.code
      assert_match "no OpenRouter key of its own", decision.reason
    end
  end

  test "admits a call only while its worst case fits under the cap" do
    @account.update_columns(openrouter_api_key: "sk-or-own")
    enable!(cap: 1)
    # Sonnet 5 caps: $4/M in, $20/M out. 100k in + 20k out = 0.4 + 0.4 = $0.80.
    call = ResidentFallback::Decision.admit_call!(@agent.reload, input_bound_tokens: 100_000, max_output_tokens: 20_000, at: @now)
    assert_equal BigDecimal("0.8"), call.reservation_usd
    assert_equal "pending", call.status
    assert_equal({ "prompt" => 4, "completion" => 20 }, call.max_price)

    # $0.20 left; a second identical call can't fit while the first is pending.
    error = assert_raises(ResidentFallback::Decision::Refused) do
      ResidentFallback::Decision.admit_call!(@agent, input_bound_tokens: 100_000, max_output_tokens: 20_000, at: @now)
    end
    assert_equal "fallback_cap_reached", error.code

    # Settled at the provider's charge, the room returns.
    call.settle!(BigDecimal("0.05"), source: "openrouter_usage_cost")
    second = ResidentFallback::Decision.admit_call!(@agent, input_bound_tokens: 100_000, max_output_tokens: 20_000, at: @now)
    assert_equal BigDecimal("0.85"), @agent.fallback_policy.committed_usd(@now)
    second.not_sent!
    assert_equal BigDecimal("0.05"), @agent.fallback_policy.committed_usd(@now)
  end

  test "a call that may have reached the provider keeps its whole reservation, refused or not" do
    @account.update_columns(openrouter_api_key: "sk-or-own")
    enable!(cap: 1)
    call = ResidentFallback::Decision.admit_call!(@agent.reload, input_bound_tokens: 100_000, max_output_tokens: 20_000, at: @now)
    call.unresolved!(http_status: 502)
    assert_equal BigDecimal("0.8"), @agent.fallback_policy.committed_usd(@now)
    assert_raises(ArgumentError) { call.not_sent! }
    assert_equal BigDecimal("0.8"), @agent.fallback_policy.committed_usd(@now)
  end

  test "output is clamped to the model's limit before the reservation is computed" do
    @account.update_columns(openrouter_api_key: "sk-or-own")
    enable!(cap: 100)
    call = ResidentFallback::Decision.admit_call!(@agent.reload, input_bound_tokens: 0, max_output_tokens: 10_000_000, at: @now)
    assert_equal 32_000, call.max_output_tokens
    assert_equal BigDecimal("0.64"), call.reservation_usd
  end

  test "the cap is per period: last month's spend doesn't count, this week's does" do
    @account.update_columns(openrouter_api_key: "sk-or-own")
    policy = enable!(cap: 1, period: "week")
    old = ResidentFallback::Decision.admit_call!(@agent.reload, input_bound_tokens: 0, max_output_tokens: 31_000, at: @now - 8.days)
    old.settle!(BigDecimal("1"), source: "openrouter_usage_cost")
    assert_equal BigDecimal("0"), policy.committed_usd(@now)
    assert_predicate ResidentFallback::Decision.for(@agent, at: @now), :ok?
    assert_equal Time.utc(2026, 11, 9), policy.period_start(@now)
    assert_equal Time.utc(2026, 11, 16), policy.period_end(@now)
  end

  test "a model that isn't on the reviewed list can't be enabled" do
    policy = ResidentFallbackPolicy.new(agent: @agent, enabled: true, model_id: "deepseek/deepseek-v4-pro-0813",
      cap_usd: 5, enabled_by_user: @owner)
    assert_not policy.valid?
    assert_includes policy.errors[:model_id], "is not a model the fallback can use"
  end

  test "turning on needs a cap and a recorded owner" do
    policy = ResidentFallbackPolicy.new(agent: @agent, enabled: true, model_id: "anthropic/claude-sonnet-5")
    assert_not policy.valid?
    assert_includes policy.errors[:cap_usd], "must be set to turn fallback on"
    assert_includes policy.errors[:enabled_by_user], "must be recorded to turn fallback on"
  end

  test "every eligible model has reviewed list and cap rates, with caps at or above list" do
    ResidentFallback::Models::ELIGIBLE.each do |id, config|
      assert Chat.model_config(id), "#{id} is in the catalogue"
      %i[prompt completion].each do |side|
        assert_operator config[:max_price][side], :>=, config[:list_price][side], "#{id} #{side}"
      end
    end
  end

end
