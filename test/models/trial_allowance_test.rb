require "test_helper"
require "support/fake_stripe"

# The free trial's house-model allowance is $10 for the whole trial, not $10
# a calendar month: a trial that crosses the 1st doesn't get a second $10.
# Once it converts, the ordinary $10 a UTC month applies, and what the trial
# drew in that month counts against it.
class TrialAllowanceTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    travel_to Time.utc(2026, 10, 25, 12)
    @account = accounts(:personal_account)
    @account.update!(billing_required: true, trial_started_at: Time.current)
    @first = agents(:research_assistant)
    @second = agents(:code_reviewer)
    @model = HouseInference::Offering::DEEPSEEK_MODEL_ID
    @offering = HouseInference::Offering.find(@model)
    [ @first, @second ].each { |agent| agent.update!(model_id: @model) }
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    sync!("sub_trial", @first, status: "trialing")
  end

  def sync!(id, agent, status:, price: CONVERSATION_PRICE)
    @stripe.put_subscription(id: id, agent: agent, customer: "cus_1", price: price, status: status)
    Billing::SubscriptionSync.new(id, client: @stripe).call
  end

  def entitlement(agent = @first) = ResidentEntitlement.find_by!(agent: agent)

  def spend!(usd, agent = @first)
    entitlement(agent).house_inference_calls.create!(agent: agent, month: HouseInference::Offering.month, model_id: @model,
      provider_route: @offering.fetch(:provider), charge_usd: usd, status: "settled")
  end

  def configured(&) = HouseInference::Offering.stub(:configured?, true, &)

  test "a trial inside one month has $10 in all" do
    assert_equal BigDecimal("10"), entitlement.allowance_limit
    spend!(BigDecimal("6.5"))
    assert_equal BigDecimal("3.5"), entitlement.allowance_remaining
  end

  test "crossing the 1st gives no second $10: the trial's earlier draws come off the new month's ceiling" do
    spend!(7)
    assert_equal BigDecimal("3"), entitlement.allowance_remaining

    travel_to Time.utc(2026, 11, 2, 9)
    assert_equal BigDecimal("3"), entitlement.allowance_limit
    assert_equal BigDecimal("0"), entitlement.allowance_spent
    assert_equal BigDecimal("3"), entitlement.allowance_remaining
    spend!(2)
    assert_equal BigDecimal("1"), entitlement.allowance_remaining
    configured do
      error = assert_raises(HouseInference::Error) do
        entitlement.reserve_house_call!(@offering.merge(reservation_usd: BigDecimal("2")), @model, agent_id: @first.id)
      end
      assert_equal "house_allowance_exhausted", error.code
    end

    spend!(1)
    assert_equal BigDecimal("0"), entitlement.allowance_remaining
    assert_equal BigDecimal("10"), HouseInferenceCall.where(free_pool: false).sum(:charge_usd), "$10 across the whole trial"
  end

  test "converted: the ordinary monthly ceiling applies, and the trial's draws that month count against it" do
    spend!(7) # October, in the trial
    travel_to Time.utc(2026, 11, 2, 9)
    spend!(2) # November, still in the trial

    travel_to Time.utc(2026, 11, 8, 12)
    sync!("sub_trial", @first, status: "active")
    assert_equal BigDecimal("10"), entitlement.allowance_limit
    assert_equal BigDecimal("2"), entitlement.allowance_spent, "November's trial draws count; October's were October's"
    assert_equal BigDecimal("8"), entitlement.allowance_remaining

    travel_to Time.utc(2026, 12, 1, 0, 30)
    assert_equal BigDecimal("10"), entitlement.allowance_remaining, "then $10 a month as usual"
  end

  test "converted in the month the trial began: what the trial drew counts against that month's $10" do
    spend!(4)
    travel_to Time.utc(2026, 10, 30, 12)
    sync!("sub_trial", @first, status: "active")
    assert_equal BigDecimal("6"), entitlement.allowance_remaining
  end

  test "a trial that ends without a card leaves no allowance" do
    spend!(3)
    travel_to Time.utc(2026, 11, 8, 12)
    sync!("sub_trial", @first, status: "canceled")
    assert_equal BigDecimal("0"), entitlement.allowance_limit
  end

  test "a resident paid for while the trial runs brings the account's ordinary monthly allowance" do
    spend!(7)
    travel_to Time.utc(2026, 11, 2, 9)
    assert_equal BigDecimal("3"), entitlement.allowance_remaining
    sync!("sub_paid", @second, status: "active")
    assert_equal BigDecimal("10"), entitlement.allowance_remaining, "the trial rule holds only while every carrier is trialing"
  end

  test "the presentation says when the trial's allowance ends" do
    ResidentSubscription.find_by!(stripe_subscription_id: "sub_trial").update!(trial_end: Time.utc(2026, 11, 8, 12))
    assert_equal "2026-11-08T12:00:00Z", entitlement.allowance_presentation[:trial_ends_at]
  end

end
