require "test_helper"
require "support/fake_stripe"

# Ending one resident's plan on the account's bill (eoXAEj slice 3, Mira
# emmNyb): the item removed with its unused time as credit, or, for the
# subscription's only item, the subscription ending at the period's end.
class Billing::EndItemTest < ActiveSupport::TestCase

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

  def locked(&) = Billing::CheckoutLock.stub(:synchronize, ->(_agent, &operation) { operation.call }, &)
  def ender(agent) = Billing::EndItem.new(agent: agent, client: @stripe)
  def quote(agent) = locked { ender(agent).quote }

  def confirm(agent, attempt, digest: Billing::EndItem.digest(attempt.quote))
    locked { ender(agent).confirm!(attempt, digest: digest) }
  end

  def shared(items, status: "active", **)
    @stripe.put_shared_subscription(id: "sub_acct", account: @account, customer: "cus_1", status: status, items: items, **)
    sync
  end

  def two = shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" }, { agent: @b, price: CONVERSATION_PRICE, id: "si_b" } ])
  def one = shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" } ])
  def sync = Billing::SubscriptionSync.new("sub_acct", client: @stripe).call
  def stored = @stripe.subscription("sub_acct")
  def item_ids = (stored[:all_items] || stored[:items][:data]).map { |item| item[:id] }
  def row(agent) = ResidentSubscription.where(agent: agent).order(:id).last

  def sweep(now: Time.current)
    locked { Billing.stub(:client, @stripe) { Billing::SweepJob.new.perform(now: now) } }
  end

  test "with other residents on the bill, a quote pins removing exactly this item, and only reads" do
    two
    @stripe.price_amounts[CONVERSATION_PRICE] = 1_500
    @stripe.proration_amount = 700

    attempt = quote(@b)

    assert_equal [ "end", "sub_acct", "si_b", nil ], [ attempt.kind, attempt.stripe_subscription_id, attempt.stripe_subscription_item_id,
                                                       attempt.submitted_at ]
    assert_equal [ { "id" => "si_b", "deleted" => true } ], attempt.create_params["items"]
    assert_equal "create_prorations", attempt.create_params["proration_behavior"]
    assert attempt.create_params["proration_date"].is_a?(Integer), "the proration date is pinned"
    assert_equal [ "delete", "cus_1", "si_b" ], attempt.quote.values_at("operation", "customer", "item")
    assert_equal(-2_200, attempt.quote["next_change"], "the next bill drops by the plan not renewed and the unused time's credit")
    assert_equal 2, attempt.quote["parent_items"].size
    assert_empty @stripe.subscription_updates, "nothing changes before the owner confirms"
  end

  test "confirming removes the item under the attempt's key; the sync ends that resident only" do
    two
    attempt = quote(@b)

    confirm(@b, attempt)

    id, params, opts = @stripe.subscription_updates.sole
    assert_equal [ "sub_acct", attempt.idempotency_key ], [ id, opts[:idempotency_key] ]
    assert_equal attempt.create_params.deep_symbolize_keys, params
    assert_equal [ "si_a" ], item_ids
    assert row(@b).ended?
    assert_not ResidentEntitlement.find_by!(agent: @b).active?
    assert ResidentEntitlement.find_by!(agent: @a).active?, "the other resident is untouched"
    assert attempt.reload.resolved_at.present?
  end

  test "the subscription's only item: it won't renew, and charges already waiting are shown" do
    one
    @stripe.put_pending_invoice_item("cus_1", 1_333)

    attempt = quote(@a)

    assert_equal "period_end", attempt.quote["operation"]
    assert_equal 1_333, attempt.quote["final_total"], "what is still billed when the period ends"
    assert_equal({ "cancel_at_period_end" => true, "metadata" => { "ending_attempt" => attempt.idempotency_key,
                                                                  "ending_agent" => @a.id.to_s } }, attempt.create_params)

    confirm(@a, attempt)

    assert stored[:cancel_at_period_end]
    assert_equal stored[:items][:data].first[:current_period_end], stored[:cancel_at], "Stripe sets cancel_at alongside"
    assert_equal [ "si_a" ], item_ids, "nothing is removed now"
    assert row(@a).cancel_at_period_end
    assert row(@a).live?, "the resident runs until the period's end"
  end

  test "an item still waiting for its resident's birth counts: ending the other resident is a removal, not the bill's end" do
    order = ResidentBirthOrder.create!(account: @account, creator: users(:user_1), tier: "conversation", rate: "standard", kind: "item",
      stripe_price_id: CONVERSATION_PRICE, stripe_subscription_id: "sub_acct", birth_attributes: { name: "Bea", system_prompt: "Be curious." })
    order.update_columns(item_submitted_at: Time.current)
    reported = []
    Rails.error.stub(:report, ->(error, **) { reported << error }) do
      shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" }, { price: CONVERSATION_PRICE, id: "si_bea", metadata: { "birth_order" => order.reference } } ])
      assert_equal 1, ResidentSubscription.live.where(stripe_subscription_id: "sub_acct").count, "only one resident is bound"

      attempt = quote(@a)
      assert_equal [ "delete", "si_a" ], attempt.quote.values_at("operation", "item")
    end
  end

  test "an item the house can't place is never treated as absent: End plan waits for it" do
    one
    stored[:items][:data] << { id: "si_stray", price: @stripe.price_object(CONVERSATION_PRICE), quantity: 1, metadata: {},
                               current_period_end: stored[:items][:data].first[:current_period_end] }

    assert_raises(Billing::InvalidSubscription) { quote(@a) }
    assert_empty @stripe.subscription_updates
    assert_not BillingCheckoutAttempt.exists?(kind: "end")
  end

  test "another item arriving between quote and confirm: a fresh quote, nothing sent" do
    one
    attempt = quote(@a)
    assert_equal "period_end", attempt.quote["operation"]
    items = stored[:items][:data]
    items << { id: "si_b", price: @stripe.price_object(CONVERSATION_PRICE), quantity: 1, metadata: { "agent_id" => @b.id.to_s },
               current_period_end: items.first[:current_period_end] }

    assert_raises(Billing::EndItem::QuoteChanged) { confirm(@a, attempt) }
    assert_empty @stripe.subscription_updates
    assert attempt.reload.resolved_at.present?
    assert_equal "delete", quote(@a).quote["operation"], "now it is one of two"
  end

  test "a quote that doesn't match what was shown is refused" do
    two
    attempt = quote(@b)

    assert_raises(Billing::EndItem::QuoteChanged) { confirm(@b, attempt, digest: "not-it") }
    assert_empty @stripe.subscription_updates
  end

  test "a bill already ending, past due or with a change pending can't end a plan" do
    shared([ { agent: @a, price: LIFE_PRICE, id: "si_a" } ], status: "past_due")
    assert_raises(Billing::EndItem::Refused) { quote(@a) }

    one
    stored[:cancel_at_period_end] = true
    assert_match(/already set to end/, assert_raises(Billing::EndItem::Refused) { quote(@a) }.message)
  end

  test "an uncertain removal is finished by the sweep with no browser, under the same key" do
    two
    attempt = quote(@b)
    @stripe.fail_next_subscription_update(applied: true)
    assert_raises(Billing::NotReady) { confirm(@b, attempt) }
    assert_nil attempt.reload.resolved_at, "an unanswered end stays open"

    sweep

    assert attempt.reload.resolved_at.present?
    assert row(@b).ended?
    keys = @stripe.subscription_updates.map { |_id, _params, opts| opts[:idempotency_key] }.uniq
    assert_equal [ attempt.idempotency_key ], keys
  end

  test "past the replay window the outcome is read from the subscription, never sent again" do
    two
    attempt = quote(@b)
    @stripe.fail_next_subscription_update(applied: false)
    assert_raises(Billing::NotReady) { confirm(@b, attempt) }
    attempt.update_columns(submitted_at: 2.days.ago)
    @stripe.subscription_updates.clear

    assert_error_reported(Billing::NotReady) { sweep }
    assert_empty @stripe.subscription_updates
    assert_nil attempt.reload.resolved_at
    assert row(@b).live?
  end

  test "the sweep drops an unsent quote left open" do
    two
    attempt = quote(@b)

    sweep(now: 2.hours.from_now)

    assert attempt.reload.resolved_at.present?
    assert_empty @stripe.subscription_updates
  end

  test "Keep undoes only an ending this resident's own End plan made" do
    one
    confirm(@a, quote(@a))
    @stripe.subscription_updates.clear

    locked { ender(@a).keep! }

    assert_not stored[:cancel_at_period_end]
    assert_not row(@a).cancel_at_period_end
    _id, params, opts = @stripe.subscription_updates.sole
    assert_equal({ cancel_at_period_end: false, metadata: { ending_attempt: "", ending_agent: "" } }, params)
    assert_match(/\Asouls-house-keep-/, opts[:idempotency_key])
  end

  test "an ending made elsewhere isn't undone from here" do
    one
    stored[:cancel_at_period_end] = true
    sync

    assert_raises(Billing::EndItem::Refused) { locked { ender(@a).keep! } }
    assert_empty @stripe.subscription_updates
    assert stored[:cancel_at_period_end]
  end

  test "a cancel date set elsewhere on top of our ending isn't undone from here" do
    one
    confirm(@a, quote(@a))
    stored[:cancel_at] = stored[:cancel_at] - 86_400
    @stripe.subscription_updates.clear

    assert_raises(Billing::EndItem::Refused) { locked { ender(@a).keep! } }
    assert_empty @stripe.subscription_updates
  end

  # Mira, #909 review: an add and an end are never both unsettled.
  def adder(agent) = Billing::AddItem.new(agent: agent, tier: Billing::Tier.find!("conversation"), rate: "standard", client: @stripe)

  def birth!
    Setting.instance.update!(allow_agents: true)
    @account.update!(billing_required: true)
    Billing::PaidBirth.new(client: @stripe).start!(account: @account, creator: users(:user_1), open_beginning: false,
      tier: Billing::Tier.find!("conversation"), attributes: { name: "Aria", system_prompt: "Be curious.", model_id: "openrouter/auto" })
  end

  test "a last-item End sent with no answer that never reached Stripe: no add or birth is sent until the sweep settles it" do
    one
    ending = quote(@a)
    @stripe.fail_next_subscription_update(applied: false)
    assert_raises(Billing::NotReady) { confirm(@a, ending) }
    assert_not stored[:cancel_at_period_end], "the parent is still active"
    @stripe.subscription_updates.clear

    assert_equal Billing::BillInFlight::END_WAITING, assert_raises(Billing::NotReady) { locked { adder(@b).quote } }.message
    assert_equal Billing::BillInFlight::END_WAITING, assert_raises(Billing::NotReady) { birth! }.message
    assert_empty @stripe.subscription_updates, "nothing is added while the end is unsettled"
    assert_not BillingCheckoutAttempt.exists?(kind: "item")
    assert_not ResidentBirthOrder.exists?(kind: "item")

    sweep

    assert ending.reload.resolved_at.present?
    assert_equal [ "si_a" ], item_ids, "the replayed ending reaches the one item it was quoted for"
    assert stored[:cancel_at_period_end]
    assert_equal [ ending.idempotency_key ], @stripe.subscription_updates.map { |_id, _params, opts| opts[:idempotency_key] }.uniq
  end

  test "an add quoted before the end was sent is not confirmed while the end is unsettled" do
    two
    added = locked { adder(@c).quote }
    ending = quote(@b)
    @stripe.fail_next_subscription_update(applied: false)
    assert_raises(Billing::NotReady) { confirm(@b, ending) }
    @stripe.subscription_updates.clear

    assert_raises(Billing::NotReady) { locked { adder(@c).confirm!(added, digest: Billing::AddItem.digest(added.quote)) } }
    assert_empty @stripe.subscription_updates
    assert_nil added.reload.submitted_at, "the add's own key is kept, unsent"
  end

  test "an add sent with no answer and nothing at Stripe yet: End waits rather than deciding lastness without it" do
    one
    added = locked { adder(@b).quote }
    @stripe.fail_next_subscription_update(applied: false)
    assert_raises(Billing::NotReady) { locked { adder(@b).confirm!(added, digest: Billing::AddItem.digest(added.quote)) } }
    @stripe.subscription_updates.clear

    assert_equal Billing::BillInFlight::ADD_WAITING, assert_raises(Billing::NotReady) { quote(@a) }.message
    assert_empty @stripe.subscription_updates
    assert_not BillingCheckoutAttempt.exists?(kind: "end")
  end

  test "a birth's item sent with no answer and nothing at Stripe yet: End waits too" do
    one
    order, = birth!
    @stripe.fail_next_subscription_update(applied: false)
    assert_raises(Billing::PaidBirth::Uncertain) { Billing::PaidBirth.new(client: @stripe).confirm_item!(order, digest: Billing::ItemQuote.digest(order.reload.item_quote)) }
    @stripe.subscription_updates.clear

    assert_equal Billing::BillInFlight::ADD_WAITING, assert_raises(Billing::NotReady) { quote(@a) }.message
    assert_empty @stripe.subscription_updates
  end

  test "an add whose answer was lost but whose item is at Stripe counts: ending the other resident is a removal" do
    one
    added = locked { adder(@b).quote }
    @stripe.fail_next_subscription_update(applied: true)
    assert_raises(Billing::NotReady) { locked { adder(@b).confirm!(added, digest: Billing::AddItem.digest(added.quote)) } }
    assert_nil added.reload.resolved_at

    assert_equal "delete", quote(@a).quote["operation"]
  end

  test "Keep applied at Stripe with its answer lost: the next Keep finishes it under the same key" do
    one
    confirm(@a, quote(@a))
    @stripe.subscription_updates.clear
    @stripe.fail_next_subscription_update(applied: true)
    assert_raises(Billing::NotReady) { locked { ender(@a).keep! } }
    assert_not stored[:cancel_at_period_end], "Stripe renews it"
    assert row(@a).cancel_at_period_end, "not yet synced"

    locked { ender(@a).keep! }

    assert_not row(@a).cancel_at_period_end
    assert BillingCheckoutAttempt.find_by!(kind: "keep", agent: @a).resolved_at.present?
    assert_equal 1, @stripe.subscription_updates.map { |_id, _params, opts| opts[:idempotency_key] }.uniq.size
  end

  test "Keep applied but its sync failed: the sweep finishes it with no browser" do
    one
    confirm(@a, quote(@a))
    Billing::SubscriptionSync.stub(:new, ->(*, **) { raise Stripe::APIConnectionError, "down" }) do
      assert_raises(Billing::NotReady) { locked { ender(@a).keep! } }
    end
    assert_not stored[:cancel_at_period_end]
    assert row(@a).cancel_at_period_end

    sweep

    assert_not row(@a).cancel_at_period_end
    assert BillingCheckoutAttempt.find_by!(kind: "keep", agent: @a).resolved_at.present?
  end

  test "a recorded Keep doesn't undo an ending made elsewhere afterwards" do
    one
    confirm(@a, quote(@a))
    @stripe.fail_next_subscription_update(applied: false)
    assert_raises(Billing::NotReady) { locked { ender(@a).keep! } }
    stored[:metadata] = (stored[:metadata] || {}).merge("ending_attempt" => "set-elsewhere")
    @stripe.subscription_updates.clear

    assert_raises(Billing::EndItem::Refused) { locked { ender(@a).keep! } }
    assert_empty @stripe.subscription_updates
    assert stored[:cancel_at_period_end]
  end

end
