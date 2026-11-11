require "test_helper"
require "support/fake_stripe"

# A resident joins the account's live subscription as one more item
# (eoXAEj slice 2a): quoted, rechecked, sent once under its attempt's key.
class Billing::AddItemTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    @a = agents(:research_assistant)
    @b = agents(:code_reviewer)
    @c = agents(:with_save_memory_tool)
    @account = @a.account
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    @stripe.put_payment_method("pm_1")
    @stripe.put_customer("cus_1", default_payment_method: "pm_1")
  end

  # Unit contracts under fixture transactions, as Billing::CheckoutTest.
  def locked(&) = Billing::CheckoutLock.stub(:synchronize, ->(_agent, &operation) { operation.call }, &)

  def add_item(agent, tier: "conversation", rate: "standard")
    Billing::AddItem.new(agent: agent, tier: Billing::Tier.find!(tier), rate: rate, client: @stripe)
  end

  def quote(agent, **) = locked { add_item(agent, **).quote }

  def confirm(agent, attempt, digest: Billing::AddItem.digest(attempt.quote))
    locked { add_item(agent).confirm!(attempt, digest: digest) }
  end

  def shared(items, status: "active", **)
    @stripe.put_shared_subscription(id: "sub_acct", account: @account, customer: "cus_1", status: status, items: items, **)
    Billing::SubscriptionSync.new("sub_acct", client: @stripe).call
  end

  def sync = Billing::SubscriptionSync.new("sub_acct", client: @stripe).call
  def items = @stripe.subscription("sub_acct")[:all_items] || @stripe.subscription("sub_acct")[:items][:data]
  def entitlement(agent) = ResidentEntitlement.find_by!(agent: agent)

  def grant!
    BillingCode.redeem!(code: BillingCode.create!(code: "PEPE", effect: "at_cost", created_by: users(:site_admin_user)).code,
      account: @account, by: users(:user_1))
  end

  test "a quote pins one update and asks Stripe only for a preview" do
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" } ])
    @stripe.price_amounts[LIFE_PRICE] = 4_000
    @stripe.price_amounts[CONVERSATION_PRICE] = 1_500
    @stripe.proration_amount = 700

    attempt = quote(@b)

    assert_equal [ "item", "sub_acct", nil ], [ attempt.kind, attempt.stripe_subscription_id, attempt.submitted_at ]
    assert_empty @stripe.subscription_updates, "nothing changes before the owner confirms"
    added = attempt.create_params["items"].sole
    assert_equal CONVERSATION_PRICE, added["price"]
    assert_equal({ "agent_id" => @b.id.to_s, "account_id" => @account.id.to_s, "tier" => "conversation",
                   "checkout_attempt" => attempt.idempotency_key }, added["metadata"])
    assert_equal "create_prorations", attempt.create_params["proration_behavior"]
    assert attempt.create_params["proration_date"].present?, "the part-period is pinned to the quote"
    assert_nil attempt.create_params["metadata"], "an account subscription needs no conversion"
    assert_equal [ 700, 5_500, 6_200, "usd" ], attempt.quote.values_at("prorated", "recurring", "next_total", "currency")
  end

  test "confirming sends the pinned update once and the resident's plan is in force on its item" do
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" } ])
    attempt = quote(@b)

    row = confirm(@b, attempt)

    id, params, opts = @stripe.subscription_updates.sole
    assert_equal [ "sub_acct", attempt.idempotency_key ], [ id, opts[:idempotency_key] ]
    assert_equal attempt.create_params.deep_symbolize_keys, params
    assert_equal [ "sub_acct", "conversation" ], [ row.stripe_subscription_id, row.tier ]
    assert_equal row.stripe_subscription_item_id, attempt.reload.stripe_subscription_item_id
    assert attempt.resolved_at.present?
    assert entitlement(@b).active?
    assert entitlement(@a).active?, "the first resident is untouched"
    assert_equal 2, items.size
  end

  test "a legacy parent is converted by the same update and its at-cost purchase keeps its provenance" do
    redemption = grant!
    @stripe.put_subscription(id: "sub_acct", agent: @a, customer: "cus_1", price: LIFE_AT_COST_PRICE, status: "active")
    @stripe.subscription("sub_acct")[:metadata].merge!(account_id: @account.id.to_s, tier: "life", rate: "at_cost",
      redemption_id: redemption.id.to_s, checkout_attempt: "souls-house-checkout-old")
    Billing::SubscriptionSync.new("sub_acct", client: @stripe).call
    redemption.withdraw!(by: users(:site_admin_user))

    attempt = quote(@b)
    conversion = attempt.create_params["items"].first
    assert_equal "si_sub_acct", conversion["id"]
    assert_equal({ "agent_id" => @a.id.to_s, "account_id" => @account.id.to_s, "tier" => "life", "rate" => "at_cost",
                   "redemption_id" => redemption.id.to_s, "checkout_attempt" => "souls-house-checkout-old" },
      conversion["metadata"])
    confirm(@b, attempt)

    metadata = @stripe.subscription("sub_acct")[:metadata].transform_keys(&:to_s)
    assert_equal "account", metadata["kind"]
    assert(%w[agent_id birth_order checkout_attempt tier rate redemption_id].all? { |key| metadata[key].blank? },
      "no subscription-level resident is left to bind the wrong item: #{metadata}")
    assert_equal redemption.id.to_s, items.first[:metadata]["redemption_id"]
    assert_equal 2, ResidentSubscription.live.where(stripe_subscription_id: "sub_acct").count
    assert entitlement(@a).active?
    assert_not AuditLog.exists?(action: "billing_rate_without_grant", auditable: @a),
      "the converted item still names the redemption that authorised it"

    sync
    assert_equal %w[si_sub_acct], ResidentSubscription.where(agent: @a).pluck(:stripe_subscription_item_id)
  end

  test "after conversion an old paid birth's link names the resident on nothing but its item" do
    @stripe.put_subscription(id: "sub_acct", agent: @a, customer: "cus_1", price: LIFE_PRICE, status: "active")
    order = ResidentBirthOrder.create!(account: @account, creator: users(:user_1), tier: "life", rate: "standard",
      stripe_subscription_id: "sub_acct", birth_attributes: { "name" => @a.name })
    order.mark_born!(agent: @a)
    @stripe.subscription("sub_acct")[:metadata].merge!(birth_order: order.reference)
    Billing::SubscriptionSync.new("sub_acct", client: @stripe).call

    confirm(@b, quote(@b))
    assert_equal order.reference, items.first[:metadata]["birth_order"]
    @stripe.subscription_updates.clear

    Billing::PaidBirth.new(client: @stripe).complete!(order)

    assert_empty @stripe.subscription_updates, "a retried link writes no resident onto the account's subscription"
    assert_equal "", @stripe.subscription("sub_acct")[:metadata]["agent_id"]
    assert entitlement(@a).active?
    assert entitlement(@b).active?
  end

  test "a parent that can't carry another resident on credit is refused before anything is pinned" do
    {
      "trialing" => [ :trialing, {} ], "past_due" => [ :unsettled, {} ], "incomplete" => [ :unsettled, {} ]
    }.each do |status, (reason, _)|
      shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" } ], status: status, trial_end: 5.days.from_now)
      error = assert_raises(Billing::AddItem::Refused, status) { quote(@b) }
      assert_equal reason, error.reason, status
    end

    { pause_collection: [ :paused, { behavior: "void" } ], pending_update: [ :pending, { expires_at: 1 } ],
      cancel_at_period_end: [ :ending, true ] }.each do |field, (reason, value)|
      shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" } ])
      @stripe.subscription("sub_acct")[field] = value
      error = assert_raises(Billing::AddItem::Refused, field.to_s) { quote(@b) }
      assert_equal reason, error.reason, field.to_s
    end

    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" } ])
    @stripe.put_customer("cus_1", default_payment_method: nil)
    assert_equal :no_card, assert_raises(Billing::AddItem::Refused) { quote(@b) }.reason

    assert_not BillingCheckoutAttempt.exists?(agent: @b)
    assert_empty @stripe.subscription_updates
  end

  test "a lost answer is replayed under the same key and the resident is added once" do
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" } ])
    attempt = quote(@b)
    @stripe.fail_next_subscription_update(applied: true)

    assert_raises(Billing::NotReady) { confirm(@b, attempt) }
    assert attempt.reload.submitted_at.present?
    assert_nil attempt.resolved_at, "an unanswered add stays blocking"

    row = confirm(@b, attempt)

    assert_equal [ false, true ], @stripe.subscription_updates.map { |_id, _params, opts| opts[:replayed] || false }
    assert_equal 2, items.size, "one item, not two"
    assert_equal "sub_acct", row.stripe_subscription_id
    assert attempt.reload.resolved_at.present?
  end

  test "the webhook settles a lost answer without the browser" do
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" } ])
    attempt = quote(@b)
    @stripe.fail_next_subscription_update(applied: true)
    assert_raises(Billing::NotReady) { confirm(@b, attempt) }

    sync

    assert attempt.reload.resolved_at.present?
    assert entitlement(@b).active?
  end

  test "past the replay window an add is found by its key, and never sent again" do
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" } ])
    attempt = quote(@b)
    @stripe.fail_next_subscription_update(applied: false)
    assert_raises(Billing::NotReady) { confirm(@b, attempt) }
    attempt.update_columns(submitted_at: 2.days.ago)
    @stripe.subscription_updates.clear

    error = assert_raises(Billing::NotReady) { confirm(@b, attempt) }
    assert_match "operator", error.message
    assert_empty @stripe.subscription_updates, "no second add under any key"
    assert_raises(Billing::NotReady) { quote(@b) }

    # Had Stripe applied it, the item carrying the key is the answer.
    late = { id: "si_late", price: { id: CONVERSATION_PRICE }, quantity: 1, current_period_end: 1.month.from_now.to_i,
             metadata: { "agent_id" => @b.id.to_s, "checkout_attempt" => attempt.idempotency_key } }
    items << late
    shown = @stripe.subscription("sub_acct")[:items][:data]
    shown << late.deep_dup unless shown.equal?(items)
    assert_equal "si_late", confirm(@b, attempt).stripe_subscription_item_id
    assert_empty @stripe.subscription_updates
  end

  test "two quotes against one parent: the second is stale once the first lands" do
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" } ])
    first = quote(@b)
    second = quote(@c)

    confirm(@b, first)
    assert_raises(Billing::AddItem::QuoteChanged) { confirm(@c, second) }

    assert second.reload.resolved_at.present?, "a stale quote is dropped, never sent"
    assert_equal [ first.idempotency_key ], @stripe.subscription_updates.map { |_id, _params, opts| opts[:idempotency_key] }
    assert_equal "sub_acct", confirm(@c, quote(@c)).stripe_subscription_id
  end

  test "a quote whose totals moved, or that the browser altered, is not sent" do
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" } ])
    attempt = quote(@b)
    @stripe.price_amounts[CONVERSATION_PRICE] = 9_900
    assert_raises(Billing::AddItem::QuoteChanged) { confirm(@b, attempt) }

    attempt = quote(@b)
    assert_raises(Billing::AddItem::QuoteChanged) { confirm(@b, attempt, digest: "0" * 64) }
    assert_empty @stripe.subscription_updates
  end

  test "Checkout refuses to open a second subscription for an account that has one" do
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" } ])

    assert_raises(Billing::AlreadySubscribed) do
      locked do
        Billing::Checkout.new(agent: @b, tier: Billing::Tier.find!("life"), client: @stripe,
          success_url: "https://souls.example/ok", cancel_url: "https://souls.example/no").url
      end
    end
    assert_empty @stripe.checkout_sessions
  end

end
