require "test_helper"
require "support/fake_stripe"

# Stripe allows a price once per subscription, so a second resident on a tier
# holds an inline copy of the tier's catalogue price (eoXAEj, jOyQnA). The
# house accepts a copy only when the actual Stripe price equals the catalogue
# price the item names.
class Billing::ItemPriceTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    @a = agents(:research_assistant)
    @b = agents(:code_reviewer)
    @c = agents(:with_save_memory_tool)
    @account = @a.account
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
  end

  def sync(**) = Billing::SubscriptionSync.new("sub_acct", client: @stripe).call(**)

  def shared(items, status: "active")
    @stripe.put_shared_subscription(id: "sub_acct", account: @account, customer: "cus_1", status: status, items: items)
  end

  def copy(price, named: price, **overrides)
    { price: @stripe.inline_price(price, **overrides), metadata: named ? { "catalogue_price" => named } : {} }
  end

  def row(agent) = ResidentSubscription.find_by!(agent: agent, stripe_subscription_id: "sub_acct")
  def change!(agent, tier) = Billing::PlanChange.new(agent: agent, tier: Billing::Tier.find!(tier), client: @stripe).call

  test "Stripe refuses one price on two items, and so does FakeStripe: the change fails and nothing moves" do
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" }, { agent: @b, price: CONVERSATION_PRICE, id: "si_b" } ])

    error = assert_raises(Stripe::InvalidRequestError) do
      @stripe.subscriptions.update("sub_acct", { items: [ { id: "si_b", price: LIFE_PRICE } ] })
    end
    assert_match(/already using that Price/, error.message)
    assert_equal CONVERSATION_PRICE, @stripe.subscription("sub_acct")[:items][:data].last[:price][:id]
    assert_raises(Stripe::InvalidRequestError) do
      shared([ { agent: @a, price: LIFE_PRICE }, { agent: @b, price: LIFE_PRICE } ])
    end
  end

  test "two residents on one tier: the catalogue price and an inline copy, both granted at that tier and rate" do
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" }, { agent: @b, id: "si_b", **copy(LIFE_PRICE) } ])
    sync

    assert_equal [ "life", "standard", LIFE_PRICE ], [ row(@a).tier, row(@a).rate, row(@a).stripe_price_id ]
    assert_equal [ "life", "standard" ], [ row(@b).tier, row(@b).rate ]
    assert_match(/\Aprice_inline_/, row(@b).stripe_price_id, "the row keeps the price Stripe actually charges")
    assert ResidentEntitlement.find_by!(agent: @b).active?
  end

  test "a third resident changing onto a taken tier gets an inline copy of exactly the catalogue price" do
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" }, { agent: @b, id: "si_b", **copy(LIFE_PRICE) },
             { agent: @c, price: CONVERSATION_PRICE, id: "si_c" } ])
    sync

    changed = change!(@c, "life")

    _id, params, = @stripe.subscription_updates.last
    item = params[:items].sole
    assert_equal "si_c", item[:id]
    assert_not item.key?(:price)
    assert_equal({ product: "prod_test_life", currency: "usd", unit_amount: 4999,
                   recurring: { interval: "month", interval_count: 1 }, tax_behavior: "exclusive" }, item[:price_data])
    assert_equal({ "catalogue_price" => LIFE_PRICE }, item[:metadata])
    assert_equal [ "life", "standard" ], [ changed.tier, changed.rate ]
    assert_equal %w[life life life], [ @a, @b, @c ].map { |agent| row(agent).tier }
    assert_equal 3, @stripe.subscription("sub_acct")[:items][:data].map { |row| row[:price][:id] }.uniq.size
  end

  test "an inline copy that differs from the catalogue price it names is the untrusted path, never a grant" do
    variants = {
      "another amount" => copy(LIFE_PRICE, unit_amount: 100),
      "another product" => copy(LIFE_PRICE, product: "prod_test_work"),
      "another currency" => copy(LIFE_PRICE, currency: "eur"),
      "another tax behaviour" => copy(LIFE_PRICE, tax_behavior: "inclusive"),
      "yearly" => copy(LIFE_PRICE, recurring: { interval: "year" }),
      "every two months" => copy(LIFE_PRICE, recurring: { interval_count: 2 }),
      "metered" => copy(LIFE_PRICE, recurring: { usage_type: "metered" }),
      "tiered" => copy(LIFE_PRICE, billing_scheme: "tiered", tiers_mode: "graduated"),
      "a quantity transform" => copy(LIFE_PRICE, transform_quantity: { divide_by: 2, round: "up" }),
      "no name" => copy(LIFE_PRICE, named: nil),
      "a name outside the catalogue" => copy(LIFE_PRICE, named: "price_somewhere_else"),
      # The at-cost price on the same product: the name says at cost, the
      # amount is the standard one. Neither grants.
      "a name for another rate" => copy(LIFE_PRICE, named: LIFE_AT_COST_PRICE)
    }
    variants.each do |label, item|
      shared([ { agent: @a, id: "si_a", **item } ])
      error = assert_raises(Billing::InvalidSubscription, label) { sync }
      assert_match "si_a", error.message, label
      assert_not ResidentSubscription.exists?(agent: @a), "#{label}: nothing recorded"
      assert_nil ResidentEntitlement.find_by(agent: @a), "#{label}: nothing granted"
    end
  end

  test "a granted resident whose price stops matching keeps only the bounded hold" do
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" }, { agent: @b, id: "si_b", **copy(LIFE_PRICE) } ])
    sync

    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" }, { agent: @b, id: "si_b", **copy(LIFE_PRICE, unit_amount: 100) } ])
    assert_raises(Billing::InvalidSubscription) { sync }
    assert row(@b).untrusted_since, "held, with a deadline"
    assert_equal "life", row(@b).tier, "not re-tiered from a guess"
    assert ResidentEntitlement.find_by!(agent: @a).active?
  end

  test "a copy of a retired catalogue price still resolves after re-costing" do
    @stripe.put_price("price_test_life_v2", product: "prod_test_life", unit_amount: 5999)
    ENV["STRIPE_PRICE_LIFE"] = "price_test_life_v2,#{LIFE_PRICE}"

    shared([ { agent: @a, price: "price_test_life_v2", id: "si_a" }, { agent: @b, id: "si_b", **copy(LIFE_PRICE) } ])
    sync

    assert_equal [ "life", "standard" ], [ row(@b).tier, row(@b).rate ]
  end

  test "a copy of an at-cost price carries its rate, and the grant check still runs on it" do
    shared([ { agent: @a, price: LIFE_AT_COST_PRICE, id: "si_a" }, { agent: @b, id: "si_b", **copy(LIFE_AT_COST_PRICE) } ])
    sync

    assert_equal [ "life", "at_cost" ], [ row(@b).tier, row(@b).rate ]
    assert_equal BigDecimal("0"), ResidentEntitlement.find_by!(agent: @b).allowance_limit
    flagged = AuditLog.where(action: "billing_rate_without_grant").map { |log| log.data["stripe_subscription_item_id"] }
    assert_includes flagged, "si_b", "no grant on this account: reported for the copy as for the catalogue price"
  end

  test "a lost answer to a plan change replays the same request and makes no second price" do
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" }, { agent: @b, price: CONVERSATION_PRICE, id: "si_b" } ])
    sync

    @stripe.fail_next_subscription_update(Stripe::APIConnectionError.new("timed out"), applied: true)
    assert_raises(Stripe::APIConnectionError) { change!(@b, "life") }
    sent_id, sent, opts = @stripe.subscription_updates.last
    inline = @stripe.subscription("sub_acct")[:items][:data].last[:price][:id]

    # The client retries the very same request: Stripe replays its answer.
    @stripe.subscriptions.update(sent_id, sent, opts.except(:replayed))
    assert @stripe.subscription_updates.last[2][:replayed]
    assert_equal inline, @stripe.subscription("sub_acct")[:items][:data].last[:price][:id]

    # The owner tries again: the change already happened, so nothing is sent.
    error = assert_raises(Billing::PlanChange::Refused) { change!(@b, "life") }
    assert_match(/already on/, error.message)
    assert_equal 2, @stripe.subscription_updates.size
    assert_equal "life", row(@b).tier
  end

  test "with no sibling on the target tier, the catalogue price itself" do
    shared([ { agent: @a, price: CONVERSATION_PRICE, id: "si_a" } ])
    sync
    change!(@a, "work")
    assert_equal [ { id: "si_a", price: WORK_PRICE, metadata: { "catalogue_price" => WORK_PRICE } } ],
      @stripe.subscription_updates.last[1][:items]
  end

end
