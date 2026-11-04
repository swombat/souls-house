require "test_helper"
require Rails.root.join("db/migrate/20261031174600_release_unreached_house_calls")

class ReleaseUnreachedHouseCallsTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(model_id: HouseInference::Offering::DEEPSEEK_MODEL_ID)
    @grant = HouseInferenceGrant.assign!(@agent, users(:user_1))
  end

  def held(status:, upstream_id: nil, charge: '0.75')
    @grant.house_inference_calls.create!(model_id: @agent.model_id, month: HouseInference::Offering.month,
      provider_route: 'openrouter', charge_usd: BigDecimal(charge), status: status, upstream_id: upstream_id, agent: @agent)
  end

  test "releases uncertain calls that never reached a model and leaves the rest" do
    unreached = 2.times.map { held(status: 'uncertain') }
    ran = held(status: 'uncertain', upstream_id: 'gen-ran')
    settled = held(status: 'settled', upstream_id: 'gen-ok', charge: '0.002')
    pending = held(status: 'pending')
    assert_equal BigDecimal('3.002'), @grant.spent

    ReleaseUnreachedHouseCalls.new.up

    unreached.each { |c| assert_equal [ 'released', BigDecimal('0') ], [ c.reload.status, c.charge_usd ] }
    assert_equal [ 'uncertain', BigDecimal('0.75') ], [ ran.reload.status, ran.charge_usd ]
    assert_equal [ 'settled', BigDecimal('0.002') ], [ settled.reload.status, settled.charge_usd ]
    assert_equal [ 'pending', BigDecimal('0.75') ], [ pending.reload.status, pending.charge_usd ]
    assert_equal BigDecimal('1.502'), @grant.spent
  end

end
