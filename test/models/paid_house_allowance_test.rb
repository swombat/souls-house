require "test_helper"

# Paid plan allowances (docs/proposals/2026-10-07-stripe-billing.md,
# "Allowance and ledger"; acceptance cases 2, 7, 8, 13 and the second half of 14).
# Since 2026-11-10 the paid allowance is the account's: $10 a month shared by
# its standard-rate residents, whatever their size (the account-wide cases are
# in AccountAllowanceTest).
class PaidHouseAllowanceTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @agent = agents(:research_assistant)
    @other = agents(:code_reviewer)
    @model = HouseInference::Offering::DEEPSEEK_MODEL_ID
    @offering = HouseInference::Offering.find(@model)
    @now = Time.utc(2026, 10, 11, 12)
    travel_to @now
  end

  # As Billing::SubscriptionSync applies it.
  def pay!(agent, tier, id: "sub_#{agent.id}_#{tier}", now: Time.current)
    sub = ResidentSubscription.find_or_initialize_by(stripe_subscription_id: id)
    sub.update!(agent: agent, account: agent.account, tier: tier, stripe_status: "active")
    apply!(sub, now: now)
    [ ResidentEntitlement.find_by!(agent: agent), sub.reload ]
  end

  def apply!(sub, now: Time.current)
    ResidentEntitlement.for_agent!(sub.agent).apply_subscription!(sub, now: now)
    sub.reload
  end

  # Settled spend so far this month. One real call can't settle above its
  # reservation (that's an overrun), so larger spend is recorded directly.
  def spend!(entitlement, agent, usd)
    entitlement.house_inference_calls.create!(agent: agent, month: HouseInference::Offering.month, model_id: @model,
      provider_route: @offering.fetch(:provider), charge_usd: usd, status: "settled")
  end

  def configured(&) = HouseInference::Offering.stub(:configured?, true, &)

  test "a paid resident's calls go to its own ledger, recording the resident" do
    @agent.update!(model_id: @model)
    entitlement, = pay!(@agent, "conversation")
    configured do
      call = entitlement.reserve_house_call!(@offering, @model, agent_id: @agent.id)
      call.settle!({ "cost" => 0.02 })
      assert_equal "settled", call.reload.status
      assert_equal BigDecimal("9.98"), entitlement.allowance_remaining
      assert_equal entitlement.id, call.resident_entitlement_id
      assert_equal @agent.id, call.agent_id
      assert_nil call.house_inference_grant_id
    end
    assert_equal BigDecimal("10"), entitlement.allowance_limit
  end

  test "two paid residents on one account share one allowance and need no free grant" do
    [ @agent, @other ].each { |agent| agent.update!(model_id: @model) }
    first, = pay!(@agent, "conversation")
    second, = pay!(@other, "work")
    # The one-free-resident-per-user rule doesn't apply to paid residents.
    assert_nil HouseInferenceGrant.assign!(@agent, @user)
    assert_nil HouseInferenceGrant.assign!(@other, @user)

    configured do
      spend!(first, @agent, 7.5)
      assert_equal BigDecimal("2.5"), first.allowance_remaining
      assert_equal BigDecimal("10"), second.allowance_limit, "the account's $10, not a second one"
      assert_equal BigDecimal("2.5"), second.allowance_remaining
      assert second.reserve_house_call!(@offering, @model, agent_id: @other.id)
      assert_equal BigDecimal("1.75"), first.allowance_remaining
    end
  end

  test "admission is strict: a call whose reservation doesn't fit is refused, and remaining never goes negative" do
    @agent.update!(model_id: @model)
    entitlement, = pay!(@agent, "conversation")
    configured do
      spend!(entitlement, @agent, 9.3)
      assert_equal BigDecimal("0.7"), entitlement.allowance_remaining
      error = assert_raises(HouseInference::Error) { entitlement.reserve_house_call!(@offering, @model, agent_id: @agent.id) }
      assert_equal "house_allowance_exhausted", error.code
      assert_equal 402, error.status
      assert_equal 1, entitlement.house_inference_calls.count # only the settled spend
    end
  end

  test "in-flight calls count at their reservation, so concurrent calls can't overspend" do
    @agent.update!(model_id: @model)
    entitlement, = pay!(@agent, "conversation")
    configured do
      spend!(entitlement, @agent, 8.0)
      entitlement.reserve_house_call!(@offering, @model, agent_id: @agent.id) # pending at 0.75
      entitlement.reserve_house_call!(@offering, @model, agent_id: @agent.id) # pending at 0.75 → 9.5
      assert_raises(HouseInference::Error) { entitlement.reserve_house_call!(@offering, @model, agent_id: @agent.id) }
    end
  end

  test "paid replaces the free grant rather than stacking with it" do
    @agent.update!(model_id: @model)
    grant = HouseInferenceGrant.assign!(@agent, @user)
    assert grant
    pay!(@agent, "conversation")
    configured do
      error = assert_raises(HouseInference::Error) { grant.reserve!(@offering, @model, agent_id: @agent.id) }
      assert_equal 409, error.status
      assert_nil Agents::InferenceAvailability.house_error(@agent)
    end
    assert_equal 0, grant.house_inference_calls.count
    assert_equal "plan", HouseInference::Allowance.presentation(@agent)[:source]
  end

  test "paid calls don't draw on the free house-wide ceiling" do
    @agent.update!(model_id: @model)
    entitlement, = pay!(@agent, "conversation")
    configured do
      HouseInference::Offering.stub(:global_limit, BigDecimal("0")) do
        assert entitlement.reserve_house_call!(@offering, @model, agent_id: @agent.id)
      end
    end
  end

  test "a resident whose plan isn't paid gets nothing from it" do
    @agent.update!(model_id: @model)
    entitlement = ResidentEntitlement.for_agent!(@agent)
    configured do
      assert_raises(HouseInference::Error) { entitlement.reserve_house_call!(@offering, @model, agent_id: @agent.id) }
    end
    assert_equal BigDecimal("0"), entitlement.allowance_limit

    paid, sub = pay!(@agent, "conversation")
    sub.update!(stripe_status: "canceled")
    paid.apply_subscription!(sub, now: Time.current)
    assert paid.reload.held?
    configured do
      assert_raises(HouseInference::Error) { paid.reserve_house_call!(@offering, @model, agent_id: @agent.id) }
    end
  end

  test "a call for another resident can't be charged to this plan" do
    [ @agent, @other ].each { |agent| agent.update!(model_id: @model) }
    entitlement, = pay!(@agent, "conversation")
    configured do
      assert_raises(HouseInference::Error) { entitlement.reserve_house_call!(@offering, @model, agent_id: @other.id) }
    end
  end

  test "resizing a resident down keeps the account's $10 and the month's spend; next month starts fresh" do
    @agent.update!(model_id: @model)
    entitlement, sub = pay!(@agent, "life")
    configured { spend!(entitlement, @agent, 6) }

    travel_to Time.utc(2026, 10, 20)
    sub.update!(tier: "conversation")
    apply!(sub)
    entitlement.reload
    assert_equal "conversation", entitlement.tier
    assert_equal BigDecimal("10"), entitlement.allowance_limit
    assert_equal BigDecimal("4"), entitlement.allowance_remaining

    travel_to Time.utc(2026, 11, 2)
    assert_equal BigDecimal("10"), entitlement.allowance_limit
    assert_equal BigDecimal("10"), entitlement.allowance_remaining
  end

  test "resizing a resident up adds no allowance, and spend so far still counts" do
    @agent.update!(model_id: @model)
    entitlement, sub = pay!(@agent, "conversation")
    configured { spend!(entitlement, @agent, 7) }
    sub.update!(tier: "work")
    apply!(sub)
    assert_equal BigDecimal("10"), entitlement.reload.allowance_limit
    assert_equal BigDecimal("3"), entitlement.allowance_remaining
  end

  # At cost: the plan funds calls (it is paid) but includes no allowance. The
  # two-clock rule (docs/proposals/2026-10-28-billing-codes-at-cost.md) kept a
  # switching resident's ceiling until the 1st; since the allowance became the
  # account's (2026-11-10) only residents at the standard rate draw on it, so a
  # resident moving to at cost stops drawing at once.
  test "at cost includes no allowance; a resident moving to at cost stops drawing on the account's at once" do
    @agent.update!(model_id: @model)
    entitlement, sub = pay!(@agent, "conversation")
    configured { spend!(entitlement, @agent, 4) }

    travel_to Time.utc(2026, 10, 20)
    sub.update!(rate: "at_cost")
    apply!(sub)
    entitlement.reload
    assert_equal "at_cost", entitlement.rate
    assert entitlement.paid?
    assert_equal BigDecimal("0"), entitlement.allowance_limit
    configured do
      error = assert_raises(HouseInference::Error) { entitlement.reserve_house_call!(@offering, @model, agent_id: @agent.id) }
      assert_match(/includes no house-model allowance/, error.message)
    end

    travel_to Time.utc(2026, 11, 2)
    assert_equal BigDecimal("0"), entitlement.allowance_limit
    assert_equal BigDecimal("0"), entitlement.allowance_remaining
    configured do
      error = assert_raises(HouseInference::Error) { entitlement.reserve_house_call!(@offering, @model, agent_id: @agent.id) }
      assert_match(/includes no house-model allowance/, error.message)
    end
    assert_equal "at_cost", entitlement.allowance_presentation[:rate]
  end

  test "a resident born at cost has a zero ceiling from the start" do
    @agent.update!(model_id: @model)
    sub = ResidentSubscription.create!(agent: @agent, account: @agent.account, stripe_subscription_id: "sub_ac",
      tier: "work", rate: "at_cost", stripe_status: "active")
    entitlement = ResidentEntitlement.for_agent!(@agent)
    entitlement.apply_subscription!(sub, now: Time.current)
    assert_equal BigDecimal("0"), entitlement.reload.allowance_limit
    configured do
      error = assert_raises(HouseInference::Error) { entitlement.reserve_house_call!(@offering, @model, agent_id: @agent.id) }
      assert_match(/includes no house-model allowance/, error.message)
    end
  end

  test "a lapse and repayment, or a replacement checkout, in the same month doesn't refill it" do
    @agent.update!(model_id: @model)
    entitlement, sub = pay!(@agent, "conversation")
    configured { spend!(entitlement, @agent, 7) }
    sub.update!(stripe_status: "canceled")
    entitlement.apply_subscription!(sub, now: Time.current)
    assert entitlement.reload.held?

    replacement, sub = pay!(@agent, "conversation", id: "sub_replacement")
    assert replacement.active?
    assert_equal BigDecimal("3"), replacement.allowance_remaining
  end

  test "a resize after the month rolled over keeps the account's $10 and the new month's spend" do
    @agent.update!(model_id: @model)
    entitlement, sub = pay!(@agent, "life")
    travel_to Time.utc(2026, 11, 15)
    configured { spend!(entitlement, @agent, 4) }
    sub.update!(tier: "conversation")
    apply!(sub)
    entitlement.reload
    assert_equal BigDecimal("10"), entitlement.allowance_limit
    assert_equal BigDecimal("6"), entitlement.allowance_remaining
  end

  test "a plan that lapses in a new month can't have that month refilled by its replacement" do
    @agent.update!(model_id: @model)
    entitlement, sub = pay!(@agent, "life")
    travel_to Time.utc(2026, 11, 10)
    configured { spend!(entitlement, @agent, 8) }
    sub.update!(stripe_status: "canceled")
    apply!(sub)
    assert entitlement.reload.held?

    travel_to Time.utc(2026, 11, 11)
    replacement, = pay!(@agent, "conversation", id: "sub_replacement")
    assert_equal BigDecimal("10"), replacement.allowance_limit
    assert_equal BigDecimal("2"), replacement.allowance_remaining

    travel_to Time.utc(2026, 12, 1)
    assert_equal BigDecimal("10"), replacement.allowance_limit
    assert_equal BigDecimal("10"), replacement.allowance_remaining
  end

  test "after grace expiry in a new month a replacement draws on the account's $10" do
    @agent.update!(model_id: @model)
    entitlement, sub = pay!(@agent, "life")
    travel_to Time.utc(2026, 11, 3)
    sub.update!(stripe_status: "past_due")
    entitlement.apply_subscription!(sub, now: Time.current)
    assert entitlement.reload.grace?
    travel_to Time.utc(2026, 11, 17)
    assert entitlement.expire_grace!(now: Time.current)
    sub.update!(stripe_status: "unpaid") # Stripe gives up later; only then can a replacement be live

    replacement, = pay!(@agent, "conversation", id: "sub_replacement")
    assert_equal BigDecimal("10"), replacement.allowance_limit
  end

  test "a member without credential rights can still edit a paid resident on a house model" do
    @agent.update!(model_id: @model)
    pay!(@agent, "conversation")
    @agent.account.stub(:ai_credentials_manageable_by?, false) do
      assert_nil HouseInferenceGrant.assign!(@agent, @user)
      @agent.update_settings!({ name: "Renamed" }, by: @user)
    end
    assert_equal "Renamed", @agent.reload.name
    assert_nil HouseInferenceGrant.find_by(agent: @agent)
  end

  test "without a paid plan the credential check still guards claiming the free grant" do
    @agent.update!(model_id: @model)
    @agent.account.stub(:ai_credentials_manageable_by?, false) do
      assert_raises(ActiveRecord::RecordInvalid) { HouseInferenceGrant.assign!(@agent, @user) }
    end
  end

end
