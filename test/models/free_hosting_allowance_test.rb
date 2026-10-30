require "test_helper"

# Free hosting carries a $10 monthly house-model allowance of its own
# (Daniel, jygXOY/jlnVNY, 2026-10-30): residents from before paying was
# possible keep working when the per-user grant is spent.
class FreeHostingAllowanceTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @agent = agents(:research_assistant)
    @other = agents(:code_reviewer)
    @model = HouseInference::Offering::DEEPSEEK_MODEL_ID
    @offering = HouseInference::Offering.find(@model)
    @now = Time.utc(2026, 10, 30, 12)
    travel_to @now
  end

  def free!(agent)
    entitlement = ResidentEntitlement.find_or_initialize_by(agent: agent)
    entitlement.update!(account: agent.account, source: "complimentary", state: "complimentary",
      complimentary_granted_at: @now)
    entitlement
  end

  def spend!(owner, agent, usd)
    owner.house_inference_calls.create!(agent: agent, month: HouseInference::Offering.month, model_id: @model,
      provider_route: @offering.fetch(:provider), charge_usd: usd, status: "settled")
  end

  def configured(&) = HouseInference::Offering.stub(:configured?, true, &)

  test "a free resident's calls go to its own $10 ledger, not the user's grant" do
    @agent.update!(model_id: @model)
    entitlement = free!(@agent)
    assert_equal BigDecimal("10"), entitlement.allowance_limit
    configured do
      call = entitlement.reserve_house_call!(@offering, @model, agent_id: @agent.id)
      assert_equal entitlement.id, call.resident_entitlement_id
      assert_nil call.house_inference_grant_id
      assert_nil Agents::InferenceAvailability.house_error(@agent)
    end
    assert_equal "free", HouseInference::Allowance.presentation(@agent)[:source]
  end

  test "a spent grant no longer stops a free resident, and two free residents of one user are independent" do
    [ @agent, @other ].each { |agent| agent.update!(model_id: @model) }
    grant = HouseInferenceGrant.create!(user: @user, agent: @agent)
    spend!(grant, @agent, 10.5)
    first = free!(@agent)
    second = free!(@other)
    # Neither claims the one free grant, so neither is refused for the other.
    assert_nil HouseInferenceGrant.assign!(@other, @user)
    configured do
      assert first.reserve_house_call!(@offering, @model, agent_id: @agent.id)
      spend!(second, @other, 9.9)
      error = assert_raises(HouseInference::Error) { second.reserve_house_call!(@offering, @model, agent_id: @other.id) }
      assert_equal "house_allowance_exhausted", error.code
      assert_match(/free allowance is used up/, error.message)
    end
  end

  test "free allowances share the house-wide ceiling with the grants" do
    @agent.update!(model_id: @model)
    entitlement = free!(@agent)
    configured do
      spend!(entitlement, @agent, 1)
      HouseInference::Offering.stub(:global_limit, BigDecimal("1")) do
        error = assert_raises(HouseInference::Error) { entitlement.reserve_house_call!(@offering, @model, agent_id: @agent.id) }
        assert_equal "house_allowance_unavailable", error.code
      end
    end
    assert_equal BigDecimal("1"), HouseInferenceCall.free.where(month: HouseInference::Offering.month).sum(:charge_usd)
  end

  test "a paid plan that ends returns to the $10, not to the paid ceiling, and its spend still counts" do
    @agent.update!(model_id: @model)
    entitlement = free!(@agent)
    sub = ResidentSubscription.create!(agent: @agent, account: @agent.account, stripe_subscription_id: "sub_free_1",
      tier: "life", stripe_status: "active")
    entitlement.apply_subscription!(sub, now: @now)
    assert_equal BigDecimal("25"), entitlement.reload.allowance_limit
    spend!(entitlement, @agent, 8)

    sub.update!(stripe_status: "canceled")
    entitlement.apply_subscription!(sub, now: @now)
    entitlement.reload
    assert entitlement.complimentary?
    assert_equal BigDecimal("10"), entitlement.allowance_limit
    assert_equal BigDecimal("2"), entitlement.allowance_remaining
  end

  test "a lapsed paid plan without free hosting stays asleep and unfunded" do
    @agent.update!(model_id: @model)
    sub = ResidentSubscription.create!(agent: @agent, account: @agent.account, stripe_subscription_id: "sub_paid_1",
      tier: "conversation", stripe_status: "active")
    entitlement = ResidentEntitlement.for_agent!(@agent)
    entitlement.apply_subscription!(sub, now: @now)
    sub.update!(stripe_status: "canceled")
    entitlement.apply_subscription!(sub, now: @now)
    entitlement.reload
    assert entitlement.held?
    assert_not entitlement.funds_calls?
    assert_equal BigDecimal("0"), entitlement.allowance_limit
  end

  test "upgrading keeps past free spend in the free pool, and it doesn't add paid spend" do
    @agent.update!(model_id: @model)
    entitlement = free!(@agent)
    month = HouseInference::Offering.month
    configured do
      entitlement.reserve_house_call!(@offering, @model, agent_id: @agent.id).settle!({ "cost" => 0.5 })
    end
    before = HouseInferenceCall.free.where(month: month).sum(:charge_usd)
    assert_equal BigDecimal("0.5"), before

    sub = ResidentSubscription.create!(agent: @agent, account: @agent.account, stripe_subscription_id: "sub_up_1",
      tier: "conversation", stripe_status: "active")
    entitlement.apply_subscription!(sub, now: @now)
    assert entitlement.reload.active?
    assert_equal before, HouseInferenceCall.free.where(month: month).sum(:charge_usd)

    configured do
      entitlement.reserve_house_call!(@offering, @model, agent_id: @agent.id).settle!({ "cost" => 0.25 })
    end
    assert_equal before, HouseInferenceCall.free.where(month: month).sum(:charge_usd)
  end

  test "cancelling back to free doesn't move past paid spend into the free pool" do
    @agent.update!(model_id: @model)
    entitlement = free!(@agent)
    month = HouseInference::Offering.month
    sub = ResidentSubscription.create!(agent: @agent, account: @agent.account, stripe_subscription_id: "sub_down_1",
      tier: "conversation", stripe_status: "active")
    entitlement.apply_subscription!(sub, now: @now)
    configured do
      entitlement.reserve_house_call!(@offering, @model, agent_id: @agent.id).settle!({ "cost" => 0.4 })
    end
    assert_equal BigDecimal("0"), HouseInferenceCall.free.where(month: month).sum(:charge_usd)

    sub.update!(stripe_status: "canceled")
    entitlement.apply_subscription!(sub, now: @now)
    assert entitlement.reload.complimentary?
    assert_equal BigDecimal("0"), HouseInferenceCall.free.where(month: month).sum(:charge_usd)
    # The resident's own $10 still counts what it spent while paid.
    assert_equal BigDecimal("9.6"), entitlement.allowance_remaining
  end

  test "the backfill puts a resident whose only entitlement is an abandoned checkout on free hosting" do
    require Rails.root.join("db/migrate/20261030080000_backfill_free_hosting_entitlements")
    @agent.update_columns(runtime: "external")
    @agent.account.update_columns(billing_required: false)
    ResidentEntitlement.where(agent: @agent).delete_all
    pending = ResidentEntitlement.for_agent!(@agent)
    pending.update_columns(checkout_session_id: "cs_abandoned")
    assert pending.reload.pending?

    ActiveRecord::Migration.suppress_messages { BackfillFreeHostingEntitlements.new.up }

    pending.reload
    assert pending.complimentary?
    assert_equal "complimentary", pending.source
    assert_equal "cs_abandoned", pending.checkout_session_id
    assert pending.funds_calls?
  end

  test "the backfill gives free hosting once, only to hosted residents with no entitlement in accounts that don't pay" do
    require Rails.root.join("db/migrate/20261030080000_backfill_free_hosting_entitlements")
    ResidentEntitlement.where(agent: [ @agent, @other ]).delete_all
    @agent.update_columns(runtime: "external")
    @other.update_columns(runtime: "external")
    paying = Account.where.not(id: @agent.account_id).first
    paying.update_columns(billing_required: true)
    @other.update_columns(account_id: paying.id)

    ActiveRecord::Migration.suppress_messages { 2.times { BackfillFreeHostingEntitlements.new.up } }

    entitlement = ResidentEntitlement.find_by!(agent: @agent)
    assert entitlement.complimentary?
    assert_equal "complimentary", entitlement.source
    assert entitlement.complimentary_granted_at
    assert_nil ResidentEntitlement.find_by(agent: @other)
    assert_equal 1, ResidentEntitlement.where(agent: @agent).count
  end

end
