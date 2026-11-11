require "test_helper"
require "support/fake_stripe"

# One subscription per account, one item per resident (eoXAEj, slice 1).
class Billing::SharedSubscriptionSyncTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    @a = agents(:research_assistant)
    @b = agents(:code_reviewer)
    @c = agents(:with_save_memory_tool)
    @account = @a.account
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
  end

  def sync(id, **) = Billing::SubscriptionSync.new(id, client: @stripe).call(**)

  def shared(items, status: "active", **)
    @stripe.put_shared_subscription(id: "sub_acct", account: @account, customer: "cus_1", status: status, items: items, **)
  end

  def row(agent) = ResidentSubscription.find_by!(agent: agent, stripe_subscription_id: "sub_acct")
  def entitlement(agent) = ResidentEntitlement.find_by!(agent: agent)

  test "each item is one resident's row, bound by its item id, and the account points at the subscription" do
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" }, { agent: @b, price: CONVERSATION_PRICE, id: "si_b" } ])

    assert_nil sync("sub_acct"), "several rows: no sole row to return"
    assert_equal "si_b", sync("sub_acct", agent: @b).stripe_subscription_item_id

    assert_equal [ "life", "si_a" ], [ row(@a).tier, row(@a).stripe_subscription_item_id ]
    assert_equal [ "conversation", "si_b" ], [ row(@b).tier, row(@b).stripe_subscription_item_id ]
    assert entitlement(@a).active?
    assert entitlement(@b).active?
    assert_equal "sub_acct", BillingCustomer.find_by!(account: @account).stripe_subscription_id
    assert_equal 2, ResidentSubscription.count, "a replayed event records nothing twice"
  end

  test "a removed item ends its resident only" do
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" }, { agent: @b, price: LIFE_PRICE, id: "si_b" } ])
    sync("sub_acct")

    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" } ])
    sync("sub_acct")

    assert_equal "canceled", row(@b).stripe_status
    assert entitlement(@b).held?
    assert entitlement(@a).active?
  end

  test "items past the embedded page are read before anything counts as removed" do
    items = [ @a, @b, @c ].each_with_index.map { |agent, i| { agent: agent, price: CONVERSATION_PRICE, id: "si_#{i}" } }
    shared(items, page_size: 1)
    @stripe.subscription_item_page_size!(1)
    sync("sub_acct")
    assert_equal %w[si_0 si_1 si_2], ResidentSubscription.order(:stripe_subscription_item_id).pluck(:stripe_subscription_item_id)

    sync("sub_acct")
    assert_equal 3, ResidentSubscription.live.count, "items on later pages are present, not removed"
  end

  test "an item with an unknown price is present: never removed, never granted, and its siblings still sync" do
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" }, { agent: @b, price: CONVERSATION_PRICE, id: "si_b" } ])
    sync("sub_acct")

    shared([ { agent: @a, price: "price_unknown", id: "si_a" }, { agent: @b, price: LIFE_PRICE, id: "si_b" } ])
    error = assert_raises(Billing::InvalidSubscription) { sync("sub_acct") }
    assert_match "si_a", error.message

    assert_equal [ "active", "life" ], [ row(@a).stripe_status, row(@a).tier ], "kept as it was, not guessed"
    assert entitlement(@a).active?
    assert_equal "life", row(@b).reload.tier, "the sibling committed"

    # The subscription going down takes the untrusted item's resident with it.
    shared([ { agent: @a, price: "price_unknown", id: "si_a" }, { agent: @b, price: LIFE_PRICE, id: "si_b" } ], status: "canceled")
    assert_raises(Billing::InvalidSubscription) { sync("sub_acct") }
    assert entitlement(@a).held?
    assert entitlement(@b).held?
  end

  test "an unknown-price item with no row grants nothing" do
    shared([ { agent: @a, price: "price_unknown" } ])
    assert_raises(Billing::InvalidSubscription) { sync("sub_acct") }
    assert_nil ResidentEntitlement.find_by(agent: @a)
    assert_not ResidentSubscription.exists?
  end

  test "an unreadable item on a live subscription is held for grace, not forever; replays don't move the deadline" do
    start = Time.zone.parse("2026-11-11 12:00")
    at = ->(time) { Billing::SubscriptionSync.new("sub_acct", client: @stripe, now: time).call }
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" }, { agent: @b, price: CONVERSATION_PRICE, id: "si_b" } ])
    at.(start)

    shared([ { agent: @a, price: "price_unknown", id: "si_a" }, { agent: @b, price: LIFE_PRICE, id: "si_b" } ])
    assert_raises(Billing::InvalidSubscription) { at.(start + 1.hour) }
    assert_equal start + 1.hour, row(@a).untrusted_since
    assert entitlement(@a).active?, "inside grace, what was granted stands"

    assert_raises(Billing::InvalidSubscription) { at.(start + 10.days) }
    assert_equal start + 1.hour, row(@a).untrusted_since, "a replay doesn't restart the hold"
    assert entitlement(@a).active?

    assert_raises(Billing::InvalidSubscription) { at.(start + 1.hour + Billing::GRACE_PERIOD) }
    assert entitlement(@a).held?, "the hold ran out with the subscription still active"
    assert_equal "active", row(@a).stripe_status, "Stripe's status is kept as Stripe's"
    assert entitlement(@b).active?, "the readable sibling is untouched"
    assert_equal "life", row(@b).tier
    assert_not ActionMailer::Base.deliveries.any? { |mail| mail.subject.to_s.match?(/payment/i) }

    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" }, { agent: @b, price: LIFE_PRICE, id: "si_b" } ])
    at.(start + 20.days)
    assert_nil row(@a).untrusted_since
    assert entitlement(@a).active?, "readable again, the plan comes back"
  end

  test "the sweep ends an unreadable item's hold when Stripe sends nothing more" do
    start = Time.zone.parse("2026-11-11 12:00")
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" }, { agent: @b, price: CONVERSATION_PRICE, id: "si_b" } ])
    Billing::SubscriptionSync.new("sub_acct", client: @stripe, now: start).call
    shared([ { agent: @a, price: "price_unknown", id: "si_a" }, { agent: @b, price: CONVERSATION_PRICE, id: "si_b" } ])
    assert_raises(Billing::InvalidSubscription) { Billing::SubscriptionSync.new("sub_acct", client: @stripe, now: start).call }

    Billing::SweepJob.perform_now(now: start + Billing::GRACE_PERIOD - 1.minute)
    assert entitlement(@a).active?

    Billing::SweepJob.perform_now(now: start + Billing::GRACE_PERIOD)
    assert entitlement(@a).held?
    assert entitlement(@b).active?
  end

  test "a quantity other than one is refused" do
    shared([ { agent: @a, price: LIFE_PRICE, quantity: 2 } ])
    assert_raises(Billing::InvalidSubscription) { sync("sub_acct") }
    assert_not ResidentSubscription.exists?
  end

  test "an item naming another account's resident is refused" do
    shared([ { agent: agents(:other_account_agent), price: LIFE_PRICE }, { agent: @a, price: LIFE_PRICE } ])
    assert_raises(Billing::InvalidSubscription) { sync("sub_acct") }
    assert_not ResidentSubscription.exists?(agent: agents(:other_account_agent))
    assert entitlement(@a).active?
  end

  test "two items naming one resident: neither is bound" do
    shared([ { agent: @a, price: LIFE_PRICE }, { agent: @a, price: CONVERSATION_PRICE } ])
    assert_raises(Billing::InvalidSubscription) { sync("sub_acct") }
    assert_not ResidentSubscription.exists?
  end

  test "item metadata contradicting the house's record changes nothing" do
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" } ])
    sync("sub_acct")

    shared([ { agent: @b, price: WORK_PRICE, id: "si_a" } ])
    assert_raises(Billing::InvalidSubscription) { sync("sub_acct") }
    assert_equal [ @a.id, "life" ], [ row(@a).agent_id, row(@a).tier ]
    assert_nil ResidentEntitlement.find_by(agent: @b)
  end

  test "the subscription's own agent_id binds only a legacy single-item subscription" do
    shared([ { price: LIFE_PRICE }, { agent: @b, price: LIFE_PRICE } ], metadata: { agent_id: @a.id.to_s })
    assert_raises(Billing::InvalidSubscription) { sync("sub_acct") }
    assert_not ResidentSubscription.exists?(agent: @a)
    assert entitlement(@b).active?
  end

  test "a row from before items records its item id on the first sync instead of a second row" do
    @stripe.put_subscription(id: "sub_old", agent: @a, customer: "cus_1", price: LIFE_PRICE, status: "active")
    legacy = ResidentSubscription.create!(agent: @a, account: @account, stripe_subscription_id: "sub_old", tier: "life",
      stripe_status: "active")

    assert_equal legacy, sync("sub_old")
    assert_equal "si_sub_old", legacy.reload.stripe_subscription_item_id
    assert_equal 1, ResidentSubscription.count
  end

  test "the Checkout that bought an item is resolved, and no other" do
    attempt = ->(key, agent) {
      BillingCheckoutAttempt.create!(agent: agent, account: @account, tier: "life", rate: "standard",
        stripe_price_id: LIFE_PRICE, idempotency_key: key, create_params: { "k" => key })
    }
    mine = attempt.call("key-a", @a)
    other = attempt.call("key-b", @b)
    @stripe.put_subscription(id: "sub_old", agent: @a, customer: "cus_1", price: LIFE_PRICE, status: "active")
    @stripe.subscription("sub_old")[:metadata]["checkout_attempt"] = "key-a"

    sync("sub_old")

    assert mine.reload.resolved_at?
    assert_not other.reload.resolved_at?
  end

  test "a resident already paid for elsewhere isn't bound twice, and the old subscription's late events can't take it back" do
    @stripe.put_subscription(id: "sub_old", agent: @a, customer: "cus_1", price: LIFE_AT_COST_PRICE, status: "active")
    sync("sub_old")
    shared([ { agent: @a, price: LIFE_AT_COST_PRICE, id: "si_a" } ])

    assert_raises(Billing::InvalidSubscription) { sync("sub_acct") }
    assert_not ResidentSubscription.exists?(stripe_subscription_id: "sub_acct"), "the old one still pays"

    @stripe.set_subscription_status("sub_old", "canceled")
    sync("sub_old")
    sync("sub_acct")
    assert_equal row(@a), entitlement(@a).current_subscription

    # A late event about the old subscription: Stripe's copy says canceled,
    # and the old row is no longer current.
    sync("sub_old")
    assert entitlement(@a).reload.active?
    assert_equal row(@a), entitlement(@a).current_subscription
  end

  test "the account keeps the first live subscription it saw as its one" do
    @stripe.put_subscription(id: "sub_first", agent: @a, customer: "cus_1", price: LIFE_PRICE, status: "active")
    @stripe.put_subscription(id: "sub_second", agent: @b, customer: "cus_1", price: LIFE_PRICE, status: "active")
    sync("sub_first")
    sync("sub_second")
    assert_equal "sub_first", BillingCustomer.find_by!(account: @account).stripe_subscription_id

    @stripe.set_subscription_status("sub_first", "canceled")
    sync("sub_first")
    sync("sub_second")
    assert_equal "sub_second", BillingCustomer.find_by!(account: @account).stripe_subscription_id
  end

  test "an unpaid first purchase doesn't become the account's subscription" do
    @stripe.put_subscription(id: "sub_new", agent: @a, customer: "cus_1", price: LIFE_PRICE, status: "incomplete")
    sync("sub_new")
    assert_nil BillingCustomer.find_by!(account: @account).stripe_subscription_id
  end

  test "a subscription naming another account is refused" do
    @stripe.put_subscription(id: "sub_x", agent: @a, customer: "cus_1", price: LIFE_PRICE, status: "active")
    @stripe.subscription("sub_x")[:metadata]["account_id"] = accounts(:team_account).id.to_s
    assert_raises(Billing::InvalidSubscription) { sync("sub_x") }
    assert_not ResidentSubscription.exists?
  end

  test "a plan change on a shared subscription moves only that resident's item" do
    shared([ { agent: @a, price: CONVERSATION_PRICE, id: "si_a" }, { agent: @b, price: CONVERSATION_PRICE, id: "si_b" } ])
    sync("sub_acct")

    changed = Billing::PlanChange.new(agent: @b, tier: Billing::Tier.find!("life"), client: @stripe).call

    assert_equal [ @b.id, "life" ], [ changed.agent_id, changed.tier ]
    id, params, = @stripe.subscription_updates.last
    assert_equal "sub_acct", id
    assert_equal [ { id: "si_b", price: LIFE_PRICE } ], params[:items]
    assert_not params.key?(:metadata), "a shared subscription isn't described as one resident's"
    assert_equal "conversation", row(@a).reload.tier
  end

  test "two residents' identical first plan changes are two mutations, under two keys" do
    shared([ { agent: @a, price: CONVERSATION_PRICE, id: "si_a" }, { agent: @b, price: CONVERSATION_PRICE, id: "si_b" } ])
    sync("sub_acct")

    Billing::PlanChange.new(agent: @a, tier: Billing::Tier.find!("life"), client: @stripe).call
    Billing::PlanChange.new(agent: @b, tier: Billing::Tier.find!("life"), client: @stripe).call

    keys = @stripe.subscription_updates.map { |_id, _params, opts| opts[:idempotency_key] }
    assert_equal 2, keys.uniq.size
    assert_not @stripe.subscription_updates.any? { |_id, _params, opts| opts[:replayed] }
    assert_equal [ "life", "life" ], [ row(@a).reload.tier, row(@b).reload.tier ]
    assert_equal [ LIFE_PRICE, LIFE_PRICE ], @stripe.subscription("sub_acct")[:items][:data].map { |item| item[:price][:id] }
  end

  test "Checkout and the sync share one lock per account" do
    keys = []
    Billing::CheckoutLock.stub(:hold, ->(namespace, id, _busy, &block) { keys << [ namespace, id ]; block.call }) do
      Billing::CheckoutLock.synchronize(@a) { }
      Billing::CheckoutLock.synchronize(@b) { }
    end
    assert_equal [ [ Billing::SubscriptionSync::LOCK_NAMESPACE, @account.id ] ] * 2, keys
  end

end
