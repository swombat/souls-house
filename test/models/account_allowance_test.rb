require "test_helper"
require "support/fake_stripe"

# The house-model allowance is the account's: $10 a UTC month, carried by one
# live standard-rate resident subscription (Billing::AllowanceCarrier), and
# what any resident of the account drew on it this month counts against it.
class AccountAllowanceTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    travel_to Time.utc(2026, 11, 10, 12)
    @account = accounts(:personal_account)
    @first = agents(:research_assistant)
    @second = agents(:code_reviewer)
    @model = HouseInference::Offering::DEEPSEEK_MODEL_ID
    @offering = HouseInference::Offering.find(@model)
    [ @first, @second ].each { |agent| agent.update!(model_id: @model) }
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
  end

  def pay!(id, agent, price: CONVERSATION_PRICE, status: "active")
    @stripe.put_subscription(id: id, agent: agent, customer: "cus_1", price: price, status: status)
    Billing::SubscriptionSync.new(id, client: @stripe).call
  end

  def entitlement(agent) = ResidentEntitlement.find_by!(agent: agent)

  def spend!(agent, usd)
    entitlement(agent).house_inference_calls.create!(agent: agent, month: HouseInference::Offering.month, model_id: @model,
      provider_route: @offering.fetch(:provider), charge_usd: usd, status: "settled")
  end

  def configured(&) = HouseInference::Offering.stub(:configured?, true, &)

  test "the first standard resident takes it; a second gets nothing, whatever its size" do
    first = pay!("sub_1", @first, price: CONVERSATION_PRICE)
    second = pay!("sub_2", @second, price: WORK_PRICE)

    assert first.includes_allowance?
    assert_not second.includes_allowance?
    assert_equal BigDecimal("10"), first.allowance_usd
    assert_equal BigDecimal("0"), second.allowance_usd
    assert_equal BigDecimal("10"), entitlement(@first).allowance_limit
    assert_equal BigDecimal("0"), entitlement(@second).allowance_limit
    assert_equal 1, ResidentSubscription.where(account: @account, includes_allowance: true).count
  end

  test "at cost never carries it, and an account with only at-cost residents has none" do
    at_cost = pay!("sub_1", @first, price: CONVERSATION_AT_COST_PRICE)
    assert_not at_cost.includes_allowance?
    assert_equal BigDecimal("0"), entitlement(@first).allowance_limit

    standard = pay!("sub_2", @second, price: CONVERSATION_PRICE)
    assert standard.includes_allowance?, "a later standard resident takes it"
    assert_not at_cost.reload.includes_allowance?
  end

  test "when the carrier ends the next live standard resident takes it, and the month's spend still counts" do
    pay!("sub_1", @first)
    pay!("sub_2", @second)
    spend!(@first, 7)
    configured { assert_equal BigDecimal("3"), entitlement(@first).allowance_remaining }

    pay!("sub_1", @first, status: "canceled")

    assert_not ResidentSubscription.find_by!(stripe_subscription_id: "sub_1").includes_allowance?
    assert ResidentSubscription.find_by!(stripe_subscription_id: "sub_2").includes_allowance?
    second = entitlement(@second)
    assert_equal BigDecimal("10"), second.allowance_limit
    assert_equal BigDecimal("7"), second.allowance_spent, "what the first drew this month counts"
    assert_equal BigDecimal("3"), second.allowance_remaining
    configured do
      error = assert_raises(HouseInference::Error) do
        second.reserve_house_call!(@offering.merge(reservation_usd: BigDecimal("4")), @model, agent_id: @second.id)
      end
      assert_equal "house_allowance_exhausted", error.code
    end
  end

  test "the oldest remaining live standard subscription takes it, not the newest" do
    third = agents(:with_save_memory_tool)
    third.update!(model_id: @model)
    pay!("sub_1", @first)
    travel 1.minute
    pay!("sub_2", @second)
    travel 1.minute
    pay!("sub_3", third)
    pay!("sub_1", @first, status: "canceled")
    assert ResidentSubscription.find_by!(stripe_subscription_id: "sub_2").includes_allowance?
    assert_not ResidentSubscription.find_by!(stripe_subscription_id: "sub_3").includes_allowance?
  end

  test "a replacement for the carrier, or a replayed webhook, never gives a second $10 in the month" do
    pay!("sub_1", @first)
    spend!(@first, 9)
    pay!("sub_1", @first) # replayed
    pay!("sub_1", @first, status: "canceled")
    pay!("sub_1", @first, status: "canceled") # replayed

    replacement = pay!("sub_1b", @first)
    assert replacement.includes_allowance?
    assert_equal BigDecimal("1"), entitlement(@first).allowance_remaining

    pay!("sub_2", @second)
    pay!("sub_1b", @first, status: "canceled")
    assert_equal BigDecimal("1"), entitlement(@second).allowance_remaining, "the account's spend follows the allowance"

    travel_to Time.utc(2026, 12, 1, 1)
    assert_equal BigDecimal("10"), entitlement(@second).allowance_remaining, "a new month starts fresh"
  end

  test "a past_due carrier keeps it through grace; once the last standard resident ends, the account has none" do
    pay!("sub_1", @first)
    pay!("sub_1", @first, status: "past_due")
    assert ResidentSubscription.find_by!(stripe_subscription_id: "sub_1").includes_allowance?
    assert entitlement(@first).grace?
    assert_equal BigDecimal("10"), entitlement(@first).allowance_limit

    pay!("sub_1", @first, status: "unpaid")
    assert_not ResidentSubscription.exists?(account: @account, includes_allowance: true)
  end

  test "the database refuses a second carrier in one account" do
    first = pay!("sub_1", @first)
    second = pay!("sub_2", @second)
    assert first.includes_allowance?
    assert_raises(ActiveRecord::RecordNotUnique) { second.update_columns(includes_allowance: true) }
  end

  test "a non-carrier on a house model is told the allowance is carried by another resident" do
    pay!("sub_1", @first)
    pay!("sub_2", @second)
    configured do
      error = assert_raises(HouseInference::Error) do
        entitlement(@second).reserve_house_call!(@offering, @model, agent_id: @second.id)
      end
      assert_equal "house_allowance_none", error.code
      assert_match(/carried by another resident/, error.message)
    end
  end

end
