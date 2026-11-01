require "test_helper"
require "support/fake_stripe"

class Billing::SubscriptionSyncTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    @agent = agents(:research_assistant)
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @agent.account, stripe_customer_id: "cus_1")
  end

  def sync(id) = Billing::SubscriptionSync.new(id, client: @stripe).call

  test "records the subscription from Stripe's current copy and activates the resident" do
    @stripe.put_subscription(id: "sub_1", agent: @agent, customer: "cus_1",
      price: FakeStripe::Helpers::LIFE_PRICE, status: "active", period_end: Time.zone.parse("2026-11-11"))

    subscription = sync("sub_1")

    assert_equal "life", subscription.tier
    assert_equal "active", subscription.stripe_status
    assert_equal Time.zone.parse("2026-11-11"), subscription.current_period_end
    entitlement = ResidentEntitlement.find_by!(agent: @agent)
    assert entitlement.active?
    assert_equal "life", entitlement.tier
  end

  test "out-of-order and duplicate events converge on Stripe's current state" do
    @stripe.put_subscription(id: "sub_1", agent: @agent, customer: "cus_1",
      price: FakeStripe::Helpers::CONVERSATION_PRICE, status: "past_due")
    # An older 'active' event processed after the 'past_due' one still reads past_due.
    sync("sub_1")
    sync("sub_1")

    assert_equal "past_due", ResidentSubscription.find_by!(stripe_subscription_id: "sub_1").stripe_status
    # Never paid, so never adopted: past_due on a first payment grants nothing.
    assert ResidentEntitlement.find_by!(agent: @agent).pending?
  end

  test "refuses a subscription that belongs to another customer" do
    @stripe.put_subscription(id: "sub_1", agent: @agent, customer: "cus_someone_else",
      price: FakeStripe::Helpers::CONVERSATION_PRICE, status: "active")

    assert_raises(Billing::InvalidSubscription) { sync("sub_1") }
    assert_not ResidentSubscription.exists?(stripe_subscription_id: "sub_1")
  end

  test "refuses a price outside the catalogue" do
    @stripe.put_subscription(id: "sub_1", agent: @agent, customer: "cus_1", price: "price_unknown", status: "active")

    assert_raises(Billing::InvalidSubscription) { sync("sub_1") }
    assert_nil ResidentEntitlement.find_by(agent: @agent)
  end

  # #619: a plan re-costed onto a new price keeps the old id in its list, so
  # the subscriptions still on it see renewals, past_due and cancellation.
  test "a subscription on a retired price keeps syncing" do
    ENV["STRIPE_PRICE_CONVERSATION"] = "#{FakeStripe::Helpers::CONVERSATION_PRICE},price_retired_conversation"
    assert_equal FakeStripe::Helpers::CONVERSATION_PRICE, Billing::Tier.find!("conversation").price_id

    @stripe.put_subscription(id: "sub_1", agent: @agent, customer: "cus_1", price: "price_retired_conversation", status: "active")
    assert_equal "conversation", sync("sub_1").tier
    assert ResidentEntitlement.find_by!(agent: @agent).active?

    @stripe.put_subscription(id: "sub_1", agent: @agent, customer: "cus_1", price: "price_retired_conversation", status: "past_due")
    sync("sub_1")
    assert ResidentEntitlement.find_by!(agent: @agent).grace?

    @stripe.put_subscription(id: "sub_1", agent: @agent, customer: "cus_1", price: "price_retired_conversation", status: "canceled")
    sync("sub_1")
    assert ResidentEntitlement.find_by!(agent: @agent).held?
  end

  test "an at-cost price records the offer it bought: the tier, the rate and no allowance" do
    @stripe.put_subscription(id: "sub_1", agent: @agent, customer: "cus_1",
      price: FakeStripe::Helpers::WORK_AT_COST_PRICE, status: "active")

    subscription = sync("sub_1")

    assert_equal "work", subscription.tier
    assert_equal "at_cost", subscription.rate
    assert_equal FakeStripe::Helpers::WORK_AT_COST_PRICE, subscription.stripe_price_id
    entitlement = ResidentEntitlement.find_by!(agent: @agent)
    assert entitlement.active?
    assert_equal "at_cost", entitlement.rate
    assert_equal BigDecimal("0"), entitlement.allowance_limit
    assert_equal "at_cost", entitlement.as_json[:rate]
    # No grant and no redemption named on the purchase: accepted, and flagged.
    flag = AuditLog.find_by!(action: "billing_rate_without_grant")
    assert_equal @agent.account, flag.account
    assert_equal "sub_1", flag.data["stripe_subscription_id"]
  end

  test "an at-cost subscription on a granted account, or one naming its redemption, is not flagged" do
    BillingCode.redeem!(code: BillingCode.create!(code: "PEPE", effect: "at_cost", created_by: users(:site_admin_user)).code,
      account: @agent.account, by: users(:user_1))
    @stripe.put_subscription(id: "sub_1", agent: @agent, customer: "cus_1",
      price: FakeStripe::Helpers::LIFE_AT_COST_PRICE, status: "active")
    sync("sub_1")
    assert_nil AuditLog.find_by(action: "billing_rate_without_grant")

    @agent.account.billing_code_redemptions.sole.withdraw!(by: users(:site_admin_user))
    @stripe.put_subscription(id: "sub_2", agent: agents(:code_reviewer), customer: "cus_1",
      price: FakeStripe::Helpers::LIFE_AT_COST_PRICE, status: "active")
    @stripe.subscription("sub_2")[:metadata]["redemption_id"] = BillingCodeRedemption.sole.id.to_s
    sync("sub_2")
    assert_nil AuditLog.find_by(action: "billing_rate_without_grant"), "a purchase that names its withdrawn grant is trusted"
  end

  test "a redemption named on the purchase counts only if it is this account's, for this rate" do
    other = accounts(:team_account)
    foreign = BillingCode.redeem!(code: BillingCode.create!(code: "THEIRS", effect: "at_cost", created_by: users(:site_admin_user)).code,
      account: other, by: users(:user_1))
    @stripe.put_subscription(id: "sub_1", agent: @agent, customer: "cus_1",
      price: FakeStripe::Helpers::LIFE_AT_COST_PRICE, status: "active")
    @stripe.subscription("sub_1")[:metadata]["redemption_id"] = foreign.id.to_s
    sync("sub_1")
    assert AuditLog.exists?(action: "billing_rate_without_grant"), "another account's grant is not this one's"

    AuditLog.where(action: "billing_rate_without_grant").delete_all
    @stripe.put_subscription(id: "sub_2", agent: agents(:code_reviewer), customer: "cus_1",
      price: FakeStripe::Helpers::LIFE_AT_COST_PRICE, status: "active")
    @stripe.subscription("sub_2")[:metadata]["redemption_id"] = "999999"
    sync("sub_2")
    assert AuditLog.exists?(action: "billing_rate_without_grant"), "a name that is no redemption counts for nothing"
  end

end
