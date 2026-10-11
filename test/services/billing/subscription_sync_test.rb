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
      price: FakeStripe::Helpers::STUDIO_PRICE, status: "active", period_end: Time.zone.parse("2026-11-11"))

    subscription = sync("sub_1")

    assert_equal "studio", subscription.tier
    assert_equal "active", subscription.stripe_status
    assert_equal Time.zone.parse("2026-11-11"), subscription.current_period_end
    entitlement = ResidentEntitlement.find_by!(agent: @agent)
    assert entitlement.active?
    assert_equal "studio", entitlement.tier
  end

  test "out-of-order and duplicate events converge on Stripe's current state" do
    @stripe.put_subscription(id: "sub_1", agent: @agent, customer: "cus_1",
      price: FakeStripe::Helpers::STARTER_PRICE, status: "past_due")
    # An older 'active' event processed after the 'past_due' one still reads past_due.
    sync("sub_1")
    sync("sub_1")

    assert_equal "past_due", ResidentSubscription.find_by!(stripe_subscription_id: "sub_1").stripe_status
    # Never paid, so never adopted: past_due on a first payment grants nothing.
    assert ResidentEntitlement.find_by!(agent: @agent).pending?
  end

  test "refuses a subscription that belongs to another customer" do
    @stripe.put_subscription(id: "sub_1", agent: @agent, customer: "cus_someone_else",
      price: FakeStripe::Helpers::STARTER_PRICE, status: "active")

    assert_raises(Billing::InvalidSubscription) { sync("sub_1") }
    assert_not ResidentSubscription.exists?(stripe_subscription_id: "sub_1")
  end

  test "refuses a price outside the catalogue" do
    @stripe.put_subscription(id: "sub_1", agent: @agent, customer: "cus_1", price: "price_unknown", status: "active")

    assert_raises(Billing::InvalidSubscription) { sync("sub_1") }
    assert_nil ResidentEntitlement.find_by(agent: @agent)
  end

end
