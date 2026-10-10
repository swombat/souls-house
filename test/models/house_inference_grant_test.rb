require 'test_helper'

class HouseInferenceGrantTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @agent = agents(:research_assistant)
    @agent.update!(model_id: HouseInference::Offering::DEEPSEEK_MODEL_ID)
    @grant = HouseInferenceGrant.assign!(@agent, @user)
    @offering = HouseInference::Offering.find(@agent.model_id)
  end

  test 'one sponsored resident across accounts and replacement preserves spending' do
    HouseInference::Offering.stub(:configured?, true) do
      call = @grant.reserve!(@offering, @agent.model_id)
      call.settle!({ 'cost' => 0.25 })
      other = agents(:other_account_agent)
      other.model_id = @agent.model_id
      assert_raises(ActiveRecord::RecordInvalid) { HouseInferenceGrant.assign!(other, @user) }
      @agent.update!(model_id: 'openrouter/auto')
      HouseInferenceGrant.assign!(@agent, @user)
      other.save!
      replacement = HouseInferenceGrant.assign!(other, @user)
      assert_equal @grant.id, replacement.id
      assert_equal BigDecimal('0.25'), replacement.spent
    end
  end

  test 'a grant moved between lookup and admission cannot be charged by the former resident' do
    @agent.update!(model_id: 'openrouter/auto')
    HouseInferenceGrant.assign!(@agent, @user)
    replacement = agents(:other_account_agent)
    replacement.update!(model_id: HouseInference::Offering::DEEPSEEK_MODEL_ID)
    HouseInferenceGrant.assign!(replacement, @user)
    HouseInference::Offering.stub(:configured?, true) do
      assert_raises(HouseInference::Error) do
        @grant.reserve!(@offering, HouseInference::Offering::DEEPSEEK_MODEL_ID, agent_id: @agent.id)
      end
    end
    assert_equal 0, @grant.house_inference_calls.count
  end

  test 'pending calls serialize spending and settlement is idempotent' do
    HouseInference::Offering.stub(:configured?, true) do
      call = @grant.reserve!(@offering, @agent.model_id)
      error = assert_raises(HouseInference::Error) { @grant.reserve!(@offering, @agent.model_id) }
      assert_equal 'house_inference_busy', error.code
      call.settle!({ 'cost' => 0.02 })
      call.settle!({ 'cost' => 0 })
      assert_equal BigDecimal('0.02'), call.reload.charge_usd
      assert @grant.reserve!(@offering, @agent.model_id)
    end
  end

  test 'separately billed BYOK usage without a usable upstream cost fails closed instead of appearing free' do
    [ { 'cost' => 0, 'is_byok' => true },
      { 'cost' => 0, 'is_byok' => true, 'cost_details' => {} },
      { 'cost' => 0, 'is_byok' => true, 'cost_details' => { 'upstream_inference_cost' => nil } },
      { 'cost' => 0, 'is_byok' => true, 'cost_details' => { 'upstream_inference_cost' => '0.001' } },
      { 'cost' => 0, 'is_byok' => true, 'cost_details' => { 'upstream_inference_cost' => -0.001 } },
      { 'cost' => 0, 'is_byok' => true, 'cost_details' => 'free' },
      { 'is_byok' => true, 'cost_details' => { 'upstream_inference_cost' => 0.001 } } ].each do |usage|
      call = @grant.house_inference_calls.create!(month: HouseInference::Offering.month, model_id: @agent.model_id,
        provider_route: @offering[:provider], charge_usd: 0.75)
      call.settle!(usage)
      assert_equal [ 'overrun', BigDecimal('0.75') ], [ call.status, call.charge_usd ], usage.inspect
    end
  end

  test 'BYOK usage is metered as the OpenRouter fee plus the provider upstream cost' do
    call = @grant.house_inference_calls.create!(month: HouseInference::Offering.month, model_id: @agent.model_id,
      provider_route: @offering[:provider], charge_usd: 0.75)
    # The shape OpenRouter returned for a house Haiku call on 2026-10-10.
    call.settle!({ 'cost' => 0, 'is_byok' => true,
      'cost_details' => { 'upstream_inference_cost' => 0.0000033, 'upstream_inference_prompt_cost' => 0.0000013 } })
    assert_equal [ 'settled', BigDecimal('0.0000033') ], [ call.status, call.charge_usd ]

    fee = @grant.house_inference_calls.create!(month: HouseInference::Offering.month, model_id: @agent.model_id,
      provider_route: @offering[:provider], charge_usd: 0.75)
    fee.settle!({ 'cost' => 0.0001, 'is_byok' => true, 'cost_details' => { 'upstream_inference_cost' => 0.002 } })
    assert_equal [ 'settled', BigDecimal('0.0021') ], [ fee.status, fee.charge_usd ]

    over = @grant.house_inference_calls.create!(month: HouseInference::Offering.month, model_id: @agent.model_id,
      provider_route: @offering[:provider], charge_usd: 0.75)
    over.settle!({ 'cost' => 0, 'is_byok' => true, 'cost_details' => { 'upstream_inference_cost' => 0.76 } })
    assert_equal [ 'overrun', BigDecimal('0.76') ], [ over.status, over.charge_usd ]
  end

  test 'fractional upstream charges round up rather than disappearing' do
    call = @grant.house_inference_calls.create!(month: HouseInference::Offering.month, model_id: @agent.model_id,
      provider_route: @offering[:provider], charge_usd: 0.75)
    call.settle!({ 'cost' => '0.000000009' })
    assert_equal BigDecimal('0.00000001'), call.reload.charge_usd
  end

  test 'missing invalid or ambiguous usage never releases the reservation' do
    [ nil, {}, { 'cost' => -1 }, { 'cost' => 'NaN' }, { 'cost' => 'Infinity' } ].each do |usage|
      call = @grant.house_inference_calls.create!(month: HouseInference::Offering.month, model_id: @agent.model_id,
        provider_route: @offering[:provider], charge_usd: 0.75)
      call.settle!(usage)
      assert_equal BigDecimal('0.75'), call.charge_usd
      assert_equal 'uncertain', call.status
    end
  end

  test 'overspend is less than one dollar and next call is refused' do
    @grant.house_inference_calls.create!(month: HouseInference::Offering.month, model_id: @agent.model_id,
      provider_route: @offering[:provider], charge_usd: 9.99, status: 'settled')
    HouseInference::Offering.stub(:configured?, true) do
      call = @grant.reserve!(@offering, @agent.model_id)
      call.settle!
      assert_operator @grant.spent, :<, 11
      error = assert_raises(HouseInference::Error) { @grant.reserve!(@offering, @agent.model_id) }
      assert_equal 'house_allowance_exhausted', error.code
      travel_to Time.utc(2026, 12, 1) do
        assert_equal 0, @grant.spent
        assert @grant.reserve!(@offering, @agent.model_id)
      end
    end
  end

  test 'global allowance and anomalous billing stop all further admission' do
    HouseInference::Offering.stub(:configured?, true) do
      HouseInference::Offering.stub(:global_limit, BigDecimal('0')) do
        assert_raises(HouseInference::Error) { @grant.reserve!(@offering, @agent.model_id) }
      end
      call = @grant.reserve!(@offering, @agent.model_id)
      call.settle!({ 'cost' => 0.76 })
      assert_equal 'overrun', call.status
      assert_equal BigDecimal('0.76'), call.charge_usd
      assert_raises(HouseInference::Error) { @grant.reserve!(@offering, @agent.model_id) }
    end
  end

  test 'revoked membership disabled account and changed route cannot spend' do
    HouseInference::Offering.stub(:configured?, true) do
      @agent.account.update!(disabled_at: Time.current)
      assert_raises(HouseInference::Error) { @grant.reserve!(@offering, @agent.model_id) }
      @agent.account.update!(disabled_at: nil)
      @user.memberships.where(account: @agent.account).update_all(confirmed_at: nil)
      assert_raises(HouseInference::Error) { @grant.reserve!(@offering, @agent.model_id) }
    end
  end

  test 'reservation bounds full context and output at enforced price caps' do
    bound = @offering[:context_tokens] * @offering[:max_price][:prompt] / 1_000_000.0 +
      @offering[:max_output_tokens] * @offering[:max_price][:completion] / 1_000_000.0
    assert_operator bound, :<, @offering[:reservation_usd]
    assert_operator @offering[:reservation_usd], :<, 1
  end

end
