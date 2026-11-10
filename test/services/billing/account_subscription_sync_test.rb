require "test_helper"
require "support/fake_stripe"

class Billing::AccountSubscriptionSyncTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
  end

  # Through the webhook's entry point: SubscriptionSync hands account plans on.
  def sync(id) = Billing::SubscriptionSync.new(id, client: @stripe).call

  test "a kind=account_plan subscription becomes the account's plan, and no resident is touched" do
    @stripe.put_account_subscription(id: "sub_a", account: @account, customer: "cus_1", price: PARTNERS_PRICE,
      status: "active", period_end: Time.zone.parse("2026-12-10"))

    subscription = sync("sub_a")

    assert_kind_of AccountSubscription, subscription
    assert_equal "partners", subscription.plan
    assert_equal PARTNERS_PRICE, subscription.stripe_price_id
    assert_equal Time.zone.parse("2026-12-10"), subscription.current_period_end
    assert_equal "partners", @account.reload.plan.id
    assert_equal "subscription", @account.plan_source
    assert_empty ResidentSubscription.where(account: @account)
    assert_nil ResidentEntitlement.find_by(agent: @agent)
  end

  test "a price outside the account plans is refused, as an unknown resident price is" do
    @stripe.put_account_subscription(id: "sub_a", account: @account, customer: "cus_1", price: "price_unknown", status: "active")
    assert_raises(Billing::InvalidSubscription) { sync("sub_a") }

    # A resident's price on an account-plan subscription is not an account plan either.
    @stripe.put_account_subscription(id: "sub_b", account: @account, customer: "cus_1", price: LIFE_PRICE, status: "active")
    assert_raises(Billing::InvalidSubscription) { sync("sub_b") }
    assert_not AccountSubscription.exists?
    assert_equal "companions", @account.plan.id
  end

  test "another customer's subscription is refused" do
    @stripe.put_account_subscription(id: "sub_a", account: @account, customer: "cus_other", price: PARTNERS_PRICE, status: "active")
    assert_raises(Billing::InvalidSubscription) { sync("sub_a") }
    assert_not AccountSubscription.exists?
  end

  test "an ended subscription drops the plan and sleeps nobody; a separately paid resident keeps its plan" do
    @stripe.put_subscription(id: "sub_r", agent: @agent, customer: "cus_1", price: CONVERSATION_PRICE, status: "active")
    sync("sub_r")
    @stripe.put_account_subscription(id: "sub_a", account: @account, customer: "cus_1", price: COLLEAGUES_PRICE, status: "active")
    sync("sub_a")
    assert_equal "colleagues", @account.reload.plan.id
    assert @agent.reload.subagents_available?

    @stripe.put_account_subscription(id: "sub_a", account: @account, customer: "cus_1", price: COLLEAGUES_PRICE, status: "canceled")
    sync("sub_a")

    assert_equal "companions", @account.reload.plan.id
    assert_not @agent.reload.subagents_available?
    entitlement = ResidentEntitlement.find_by!(agent: @agent)
    assert entitlement.active?, "the resident is paid for separately and stays awake"
    assert ResidentSubscription.find_by!(stripe_subscription_id: "sub_r").includes_allowance?
  end

  test "ending a resident's subscription never touches the account's" do
    @stripe.put_account_subscription(id: "sub_a", account: @account, customer: "cus_1", price: PARTNERS_PRICE, status: "active")
    sync("sub_a")
    @stripe.put_subscription(id: "sub_r", agent: @agent, customer: "cus_1", price: CONVERSATION_PRICE, status: "active")
    sync("sub_r")
    @stripe.put_subscription(id: "sub_r", agent: @agent, customer: "cus_1", price: CONVERSATION_PRICE, status: "canceled")
    sync("sub_r")

    assert ResidentEntitlement.find_by!(agent: @agent).held?
    assert_equal "active", AccountSubscription.find_by!(stripe_subscription_id: "sub_a").stripe_status
    assert_equal "partners", @account.reload.plan.id
  end

  test "past_due keeps the plan through the grace period and remembers when it began" do
    @stripe.put_account_subscription(id: "sub_a", account: @account, customer: "cus_1", price: PARTNERS_PRICE, status: "active")
    sync("sub_a")
    @stripe.put_account_subscription(id: "sub_a", account: @account, customer: "cus_1", price: PARTNERS_PRICE, status: "past_due")
    began = Time.current
    sync("sub_a")
    travel 1.day
    sync("sub_a") # a replay doesn't restart the grace

    subscription = AccountSubscription.sole
    assert_in_delta began, subscription.past_due_since, 1.second
    assert_equal "partners", @account.reload.plan.id
    travel Billing::GRACE_PERIOD
    assert_equal "companions", @account.reload.plan.id

    @stripe.put_account_subscription(id: "sub_a", account: @account, customer: "cus_1", price: PARTNERS_PRICE, status: "active")
    sync("sub_a")
    assert_nil subscription.reload.past_due_since
    assert_equal "partners", @account.reload.plan.id
  end

  test "a second live plan for one account is refused" do
    @stripe.put_account_subscription(id: "sub_a", account: @account, customer: "cus_1", price: PARTNERS_PRICE, status: "active")
    sync("sub_a")
    @stripe.put_account_subscription(id: "sub_b", account: @account, customer: "cus_1", price: COLLEAGUES_PRICE, status: "active")
    assert_raises(Billing::InvalidSubscription) { sync("sub_b") }
    assert_equal [ "sub_a" ], AccountSubscription.pluck(:stripe_subscription_id)
  end

  test "an account subscription naming an account that isn't here is refused" do
    @stripe.put_account_subscription(id: "sub_a", account: Account.new(id: 999_999), customer: "cus_1", price: PARTNERS_PRICE,
      status: "active")
    assert_raises(Billing::InvalidSubscription) { sync("sub_a") }
  end

end
