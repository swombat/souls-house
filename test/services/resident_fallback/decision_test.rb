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
    # Sonnet 5 reserves $4.24/M in, $10.60/M out. 100k in + 20k out = 0.424 + 0.212 = $0.636.
    call = ResidentFallback::Decision.admit_call!(@agent.reload, input_bound_tokens: 100_000, max_output_tokens: 20_000, at: @now)
    assert_equal BigDecimal("0.636"), call.reservation_usd
    assert_equal "pending", call.status
    assert_equal({ "prompt" => 2, "completion" => 10 }, call.max_price)

    # $0.364 left; a second identical call can't fit while the first is pending.
    error = assert_raises(ResidentFallback::Decision::Refused) do
      ResidentFallback::Decision.admit_call!(@agent, input_bound_tokens: 100_000, max_output_tokens: 20_000, at: @now)
    end
    assert_equal "fallback_cap_reached", error.code

    # Settled at the provider's charge, the room returns.
    call.settle!(BigDecimal("0.05"), source: "openrouter_usage_cost")
    second = ResidentFallback::Decision.admit_call!(@agent, input_bound_tokens: 100_000, max_output_tokens: 20_000, at: @now)
    assert_equal BigDecimal("0.686"), @agent.fallback_policy.committed_usd(@now)
    second.not_sent!
    assert_equal BigDecimal("0.05"), @agent.fallback_policy.committed_usd(@now)
  end

  test "a call that may have reached the provider keeps its whole reservation, refused or not" do
    @account.update_columns(openrouter_api_key: "sk-or-own")
    enable!(cap: 1)
    call = ResidentFallback::Decision.admit_call!(@agent.reload, input_bound_tokens: 100_000, max_output_tokens: 20_000, at: @now)
    call.unresolved!(http_status: 502)
    assert_equal BigDecimal("0.636"), @agent.fallback_policy.committed_usd(@now)
    assert_equal false, call.not_sent!
    assert_equal "unresolved", call.reload.status
    assert_equal BigDecimal("0.636"), @agent.fallback_policy.committed_usd(@now)
    # Billing resolved later: the known charge replaces the reservation.
    assert call.settle!(BigDecimal("0.3"), source: "openrouter_generation_lookup")
    assert_equal BigDecimal("0.3"), @agent.fallback_policy.committed_usd(@now)
  end

  test "a call is never settled at an unknown charge (Mira #871: NULL settle dropped the reservation)" do
    @account.update_columns(openrouter_api_key: "sk-or-own")
    enable!(cap: 1)
    call = ResidentFallback::Decision.admit_call!(@agent.reload, input_bound_tokens: 100_000, max_output_tokens: 20_000, at: @now)
    assert_raises(ArgumentError) { call.settle!(nil, source: "openrouter_usage_cost") }
    assert_raises(ArgumentError) { call.settle!(BigDecimal("-0.01"), source: "openrouter_usage_cost") }
    assert_equal "pending", call.reload.status
    assert_equal BigDecimal("0.636"), @agent.fallback_policy.committed_usd(@now)
    # Nor can a write that bypasses the model leave a settled NULL behind.
    assert_raises(ActiveRecord::StatementInvalid) { call.update_columns(status: "settled", charge_usd: nil) }
  end

  test "a non-finite charge is refused and the reservation stays held (Mira #871)" do
    @account.update_columns(openrouter_api_key: "sk-or-own")
    enable!(cap: 1)
    call = ResidentFallback::Decision.admit_call!(@agent.reload, input_bound_tokens: 100_000, max_output_tokens: 20_000, at: @now)
    [ BigDecimal("NaN"), BigDecimal("Infinity"), "NaN", "not a number" ].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { call.settle!(bad, source: "openrouter_usage_cost") }
    end
    assert_equal "pending", call.reload.status
    # The reservation stays held, and a second call still can't fit.
    assert_equal BigDecimal("0.636"), @agent.fallback_policy.committed_usd(@now)
    error = assert_raises(ResidentFallback::Decision::Refused) do
      ResidentFallback::Decision.admit_call!(@agent, input_bound_tokens: 100_000, max_output_tokens: 20_000, at: @now)
    end
    assert_equal "fallback_cap_reached", error.code
    call.charge_usd = BigDecimal("NaN")
    assert_not call.valid?
  end

  test "the database refuses a NaN amount even when the model is bypassed (Mira #871)" do
    @account.update_columns(openrouter_api_key: "sk-or-own")
    enable!(cap: 1)
    call = ResidentFallback::Decision.admit_call!(@agent.reload, input_bound_tokens: 100_000, max_output_tokens: 20_000, at: @now)
    assert_raises(ActiveRecord::StatementInvalid) do
      ResidentFallbackCall.connection.execute("UPDATE resident_fallback_calls SET status = 'settled', charge_usd = 'NaN' WHERE id = #{call.id}")
    end
  end

  test "a stale or late callback never overwrites a known settlement (Mira #871)" do
    @account.update_columns(openrouter_api_key: "sk-or-own")
    enable!(cap: 1)
    stale = ResidentFallback::Decision.admit_call!(@agent.reload, input_bound_tokens: 100_000, max_output_tokens: 20_000, at: @now)
    assert ResidentFallbackCall.find(stale.id).settle!(BigDecimal("0.3"), source: "openrouter_usage_cost")

    # `stale` still believes it is pending.
    assert_equal "pending", stale.status
    assert_equal false, stale.not_sent!
    assert_equal false, stale.unresolved!(http_status: 502)
    assert_equal false, stale.settle!(BigDecimal("0.01"), source: "openrouter_usage_cost")
    stale.reload
    assert_equal [ "settled", BigDecimal("0.3") ], [ stale.status, stale.charge_usd ]
    assert_equal BigDecimal("0.3"), @agent.fallback_policy.committed_usd(@now)
  end

  test "changing the cap period keeps every call inside the new window (Mira #871)" do
    @account.update_columns(openrouter_api_key: "sk-or-own")
    policy = enable!(cap: 2, period: "month")
    # Tue 3 Nov (last week, this month) and Mon 9 Nov (this week).
    ResidentFallback::Decision.admit_call!(@agent.reload, input_bound_tokens: 0, max_output_tokens: 1_000, at: Time.utc(2026, 11, 3, 9))
      .settle!(BigDecimal("0.4"), source: "openrouter_usage_cost")
    ResidentFallback::Decision.admit_call!(@agent, input_bound_tokens: 0, max_output_tokens: 1_000, at: Time.utc(2026, 11, 9, 9))
      .settle!(BigDecimal("0.9"), source: "openrouter_usage_cost")
    assert_equal BigDecimal("1.3"), policy.committed_usd(@now)

    policy.update!(cap_period: "week")
    assert_equal BigDecimal("0.9"), policy.reload.committed_usd(@now), "month → week keeps this week's call"

    policy.update!(cap_period: "month")
    assert_equal BigDecimal("1.3"), policy.reload.committed_usd(@now), "week → month keeps the month's earlier call"
  end

  test "output is clamped to the model's limit before the reservation is computed" do
    @account.update_columns(openrouter_api_key: "sk-or-own")
    enable!(cap: 100)
    call = ResidentFallback::Decision.admit_call!(@agent.reload, input_bound_tokens: 0, max_output_tokens: 10_000_000, at: @now)
    assert_equal 32_000, call.max_output_tokens
    assert_equal BigDecimal("0.3392"), call.reservation_usd
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

  test "every eligible model pins its vendor at list price, and its reservation covers the route's dearest rates plus the fee" do
    ResidentFallback::Models::ELIGIBLE.each do |id, config|
      assert Chat.model_config(id), "#{id} is in the catalogue"
      assert config[:provider].present?, "#{id} is pinned to a vendor"
      # max_price at list keeps the dearer regional and "fast" endpoints out.
      assert_equal config[:list_price], config[:max_price], id
      prices = ResidentFallback::Models::ROUTE_PRICES.fetch(id)
      fee = BigDecimal("1.05")
      assert_operator config[:reservation_rate][:prompt], :>=, BigDecimal(prices[:input].max.to_s) * fee, "#{id} input"
      assert_operator config[:reservation_rate][:completion], :>=, BigDecimal(prices[:output].max.to_s) * fee, "#{id} output"
      assert_operator config[:max_output_tokens], :<=, 128_000, "#{id} output within the endpoint's limit"
    end
  end

  test "a call built for a model the owner has since changed is refused under the lock, not priced at the new one (Mira #887)" do
    @account.update_columns(openrouter_api_key: "sk-or-own")
    policy = enable!(cap: 10)
    built_for = policy.model_id
    ResidentFallbackPolicy.find(policy.id).update!(model_id: "anthropic/claude-opus-5.5")
    error = assert_raises(ResidentFallback::Decision::Refused) do
      ResidentFallback::Decision.admit_call!(@agent.reload, input_bound_tokens: 1_000, max_output_tokens: 1_000, model_id: built_for, at: @now)
    end
    assert_equal "fallback_model_unavailable", error.code
    assert_equal 0, ResidentFallbackCall.count
  end

end
