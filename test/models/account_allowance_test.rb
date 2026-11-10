require "test_helper"
require "support/fake_stripe"

# The house-model allowance is the account's: $10 a UTC month, shared by every
# resident whose plan funds calls at the standard rate, and what any of them
# drew on it this month counts against it (ResidentEntitlement#allowance_limit).
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

  def reserve!(agent, usd = nil)
    offering = usd ? @offering.merge(reservation_usd: BigDecimal(usd.to_s)) : @offering
    entitlement(agent).reserve_house_call!(offering, @model, agent_id: agent.id)
  end

  def configured(&) = HouseInference::Offering.stub(:configured?, true, &)

  # Mira's review, finding 1: a second standard-rate resident on a house
  # model works, sharing the account's $10.
  test "two standard residents of any size each make house calls, and the second is refused only when the account's $10 is used up" do
    pay!("sub_1", @first, price: CONVERSATION_PRICE)
    pay!("sub_2", @second, price: WORK_PRICE)
    assert_equal BigDecimal("10"), entitlement(@first).allowance_limit
    assert_equal BigDecimal("10"), entitlement(@second).allowance_limit, "the same $10, not a second one"

    configured do
      reserve!(@first).settle!({ "cost" => 0.5 })
      reserve!(@second).settle!({ "cost" => 0.25 })
      assert_equal BigDecimal("9.25"), entitlement(@first).allowance_remaining
      assert_equal BigDecimal("9.25"), entitlement(@second).allowance_remaining

      spend!(@first, 8.5)
      assert_equal BigDecimal("0.75"), entitlement(@second).allowance_remaining
      reserve!(@second, "0.75").settle!({ "cost" => 0.75 })

      error = assert_raises(HouseInference::Error) { reserve!(@second, "0.01") }
      assert_equal "house_allowance_exhausted", error.code
      assert_equal 402, error.status
      assert_equal "This account's house-model allowance is used up for this month. It resets at the start of next month (UTC).",
        error.message
      assert_raises(HouseInference::Error) { reserve!(@first, "0.01") }
    end
    assert_equal BigDecimal("10"), HouseInferenceCall.where(free_pool: false).sum(:charge_usd), "$10 for the account in all"
  end

  test "at cost draws nothing, and an account with only at-cost residents has nothing to draw" do
    pay!("sub_1", @first, price: CONVERSATION_AT_COST_PRICE)
    assert_equal BigDecimal("0"), entitlement(@first).allowance_limit
    configured do
      error = assert_raises(HouseInference::Error) { reserve!(@first) }
      assert_equal "house_allowance_none", error.code
      assert_match(/hosted at cost/, error.message)
    end

    pay!("sub_2", @second, price: CONVERSATION_PRICE)
    assert_equal BigDecimal("10"), entitlement(@second).allowance_limit
    assert_equal BigDecimal("0"), entitlement(@first).allowance_limit, "still nothing at cost"
  end

  test "when a resident ends, the others keep drawing, and the month's spend still counts" do
    pay!("sub_1", @first)
    pay!("sub_2", @second)
    spend!(@first, 7)

    pay!("sub_1", @first, status: "canceled")

    assert_equal BigDecimal("0"), entitlement(@first).allowance_limit
    second = entitlement(@second)
    assert_equal BigDecimal("10"), second.allowance_limit
    assert_equal BigDecimal("7"), second.allowance_spent, "what the first drew this month counts"
    assert_equal BigDecimal("3"), second.allowance_remaining
    configured do
      error = assert_raises(HouseInference::Error) { reserve!(@second, 4) }
      assert_equal "house_allowance_exhausted", error.code
    end
  end

  test "a replacement, a lapse and repayment, or a replayed webhook never gives a second $10 in the month" do
    pay!("sub_1", @first)
    spend!(@first, 9)
    pay!("sub_1", @first) # replayed
    pay!("sub_1", @first, status: "canceled")
    pay!("sub_1", @first, status: "canceled") # replayed

    pay!("sub_1b", @first)
    assert_equal BigDecimal("1"), entitlement(@first).allowance_remaining

    pay!("sub_2", @second)
    assert_equal BigDecimal("1"), entitlement(@second).allowance_remaining
    pay!("sub_1b", @first, status: "canceled")
    assert_equal BigDecimal("1"), entitlement(@second).allowance_remaining, "the account's spend stays the account's"

    travel_to Time.utc(2026, 12, 1, 1)
    assert_equal BigDecimal("10"), entitlement(@second).allowance_remaining, "a new month starts fresh"
  end

  test "a past_due resident keeps drawing through grace; once it ends it draws nothing" do
    pay!("sub_1", @first)
    pay!("sub_1", @first, status: "past_due")
    assert entitlement(@first).grace?
    assert_equal BigDecimal("10"), entitlement(@first).allowance_limit

    pay!("sub_1", @first, status: "unpaid")
    assert entitlement(@first).held?
    assert_equal BigDecimal("0"), entitlement(@first).allowance_limit
  end

  # Mira's review, finding 2: the house's own grace deadline puts A to sleep
  # while Stripe still says past_due. A draws nothing more; B keeps the
  # account's remaining allowance, and A's spend this month still counts.
  test "a resident held when local grace expires while Stripe says past_due neither draws nor blocks the others" do
    pay!("sub_a", @first)
    pay!("sub_b", @second)
    spend!(@first, 4)
    pay!("sub_a", @first, status: "past_due")
    assert entitlement(@first).grace?

    travel Billing::GRACE_PERIOD + 1.minute
    assert entitlement(@first).expire_grace!
    pay!("sub_a", @first, status: "past_due") # Stripe still says past_due; a replay changes nothing

    a = entitlement(@first)
    assert a.held?
    assert_equal "past_due", ResidentSubscription.find_by!(stripe_subscription_id: "sub_a").stripe_status
    assert_equal BigDecimal("0"), a.allowance_limit
    b = entitlement(@second)
    assert_equal BigDecimal("10"), b.allowance_limit
    assert_equal BigDecimal("4"), b.allowance_spent, "A's earlier spend this month still counts"
    assert_equal BigDecimal("6"), b.allowance_remaining
    configured do
      assert_raises(HouseInference::Error) { reserve!(@first) }
      assert reserve!(@second)
    end
  end

  test "free hosting keeps its own $10, apart from the account's" do
    free = agents(:with_save_memory_tool)
    free.update!(model_id: @model)
    complimentary = ResidentEntitlement.create!(agent: free, account: @account, source: "complimentary",
      state: "complimentary", complimentary_granted_at: Time.current)
    pay!("sub_1", @first)
    spend!(@first, 10)
    assert_equal BigDecimal("0"), entitlement(@first).allowance_remaining

    assert_equal BigDecimal("10"), complimentary.allowance_remaining
    configured do
      reserve!(free).settle!({ "cost" => 0.5 })
      assert_raises(HouseInference::Error) { reserve!(@first, "0.01") }
    end
    assert_equal BigDecimal("9.5"), complimentary.allowance_remaining
    assert_equal BigDecimal("10"), entitlement(@first).allowance_spent, "its spend isn't the account's"
  end

end
