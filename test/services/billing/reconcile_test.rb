require "test_helper"
require "support/fake_stripe"

# One bill per account: every change is a BillChange, proposed with Stripe's
# preview, confirmed, sent once under its key, and applied to the house by
# BillSync when Stripe carries its lines.
class Billing::ReconcileTest < ActiveSupport::TestCase

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
    @now = Time.utc(2026, 11, 14, 12)
    travel_to @now
  end

  # The account's subscription as Stripe holds it, and the rows the house
  # holds on it: residents: { agent => price }, plan: a price or nil.
  def bill!(plan: nil, status: "active", id: "sub_acct", **residents)
    lines = residents.values.tally.map { |price, quantity| { price:, quantity: } }
    lines << { price: plan, quantity: 1 } if plan
    @stripe.put_shared_subscription(id:, account: @account, customer: "cus_1", status:, items: lines)
    residents.each do |agent, price|
      offer = Billing::Offer.for_price(price)
      row = ResidentSubscription.create!(agent:, account: @account, stripe_subscription_id: id, tier: offer.tier.id,
        rate: offer.rate, stripe_price_id: price, stripe_status: status)
      ResidentEntitlement.for_agent!(agent).apply_subscription!(row)
    end
    if plan
      AccountSubscription.create!(account: @account, stripe_subscription_id: id, stripe_status: status,
        plan: Billing::AccountPlan.for_price(plan).id, stripe_price_id: plan)
    end
    sync(id)
  end

  def reconcile(now: Time.current) = Billing::Reconcile.new(account: @account, client: @stripe, now:)
  def sync(id = "sub_acct") = Billing::BillSync.new(id, client: @stripe).call
  def remote(id = "sub_acct") = Billing::BillSync.remote_lines(@stripe.subscriptions.retrieve(id), client: @stripe)
  def add(agent, price) = { op: "add", agent_id: agent.id, price: }
  def go!(ops) = reconcile.propose(ops).then { |change| reconcile.confirm(change, digest: change.digest) }
  def paid?(agent) = ResidentEntitlement.paid_for?(agent)

  test "a second resident at the same price is the same line, twice: sent once, on the next invoice, then the house follows" do
    bill!(@a => CONVERSATION_PRICE)
    change = reconcile.propose([ add(@b, CONVERSATION_PRICE) ])

    assert change.proposed?
    assert_equal({ CONVERSATION_PRICE => 1 }, change.base)
    assert_equal({ CONVERSATION_PRICE => 2 }, change.wanted)
    assert_equal 2499 + 500, change.quote["added_next"], "its month and its part-period, on the next bill"
    assert_equal 2 * 2499, change.quote["recurring_total"]
    assert_empty @stripe.subscription_updates, "a proposal only reads"
    assert_not paid?(@b)

    change = reconcile.confirm(change, digest: change.digest)

    id, params, opts = @stripe.subscription_updates.sole
    assert_equal "sub_acct", id
    assert_equal [ { id: "si_sub_acct_0", quantity: 2 } ], params[:items]
    assert_equal "create_prorations", params[:proration_behavior]
    assert_equal @now.to_i, params[:proration_date]
    assert_equal change.idempotency_key, opts[:idempotency_key]
    assert change.applied?
    assert paid?(@b)
    assert_equal({ CONVERSATION_PRICE => 2 }, Billing::BillSync.house_lines("sub_acct"))
    assert_equal [ { price: CONVERSATION_PRICE, quantity: 2 } ], Billing::Bill.new(@account).items
  end

  test "a resident at another price is a new line; ending one of two takes its line off now and leaves the other" do
    bill!(@a => CONVERSATION_PRICE)
    go!([ add(@b, LIFE_PRICE) ])
    assert_equal [ { price: LIFE_PRICE, quantity: 1 } ], @stripe.subscription_updates.last[1][:items]
    assert_equal({ CONVERSATION_PRICE => 1, LIFE_PRICE => 1 }, remote)

    change = reconcile.propose_end(@a)
    assert_equal [ { "op" => "end", "agent_id" => @a.id } ], change.ops
    assert_equal(-2499 - 500, change.quote["added_next"])
    reconcile.confirm(change, digest: change.digest)

    assert_equal [ { id: "si_sub_acct_0", deleted: true } ], @stripe.subscription_updates.last[1][:items]
    assert_not paid?(@a)
    assert paid?(@b)
    assert_equal({ LIFE_PRICE => 1 }, remote)
    assert_equal "canceled", ResidentSubscription.find_by!(agent: @a).stripe_status
  end

  test "ending one of two at the same price lowers the quantity" do
    bill!(@a => CONVERSATION_PRICE, @b => CONVERSATION_PRICE)
    reconcile.propose_end(@b).then { |change| reconcile.confirm(change, digest: change.digest) }

    assert_equal [ { id: "si_sub_acct_0", quantity: 1 } ], @stripe.subscription_updates.sole[1][:items]
    assert paid?(@a)
    assert_not paid?(@b)
  end

  test "ending the only resident ends the bill at the period's end; keeping it undoes exactly that" do
    bill!(@a => CONVERSATION_PRICE)
    change = reconcile.propose_end(@a)
    assert_equal [ { "op" => "end_bill", "agent_id" => @a.id } ], change.ops
    assert change.quote["ends"]
    assert reconcile.confirm(change, digest: change.digest).applied?

    assert_equal({ cancel_at_period_end: true }, @stripe.subscription_updates.sole[1])
    assert paid?(@a), "it runs to the period's end"
    assert ResidentSubscription.find_by!(agent: @a).cancel_at_period_end

    error = assert_raises(Billing::Reconcile::Refused) { reconcile.propose([ add(@b, CONVERSATION_PRICE) ]) }
    assert_match(/set to end/, error.message)

    assert go!([ { op: "keep_bill", agent_id: @a.id } ]).applied?
    assert_not ResidentSubscription.find_by!(agent: @a).cancel_at_period_end
  end

  test "a resize moves the resident between lines at its own rate" do
    bill!(@a => CONVERSATION_PRICE, @b => CONVERSATION_PRICE)
    go!([ { op: "resize", agent_id: @b.id, price: LIFE_PRICE } ])

    assert_equal [ { id: "si_sub_acct_0", quantity: 1 }, { price: LIFE_PRICE, quantity: 1 } ].sort_by(&:to_s),
      @stripe.subscription_updates.sole[1][:items].sort_by(&:to_s)
    assert_equal %w[life standard], ResidentSubscription.find_by!(agent: @b).then { |row| [ row.tier, row.rate ] }
    assert_equal "life", ResidentEntitlement.find_by!(agent: @b).tier

    assert_raises(Billing::Reconcile::Refused) { reconcile.propose([ { op: "resize", agent_id: @b.id, price: WORK_AT_COST_PRICE } ]) }
  end

  test "the plan is a line on the same bill: bought, changed and dropped" do
    bill!(@a => CONVERSATION_PRICE)
    go!([ { op: "plan", price: PARTNERS_PRICE } ])
    assert_equal "partners", @account.reload.plan.id
    assert_equal({ CONVERSATION_PRICE => 1, PARTNERS_PRICE => 1 }, remote)

    go!([ { op: "plan", price: COLLEAGUES_PRICE } ])
    assert_equal "colleagues", @account.reload.plan.id
    assert_equal({ CONVERSATION_PRICE => 1, COLLEAGUES_PRICE => 1 }, remote)
    assert_equal 1, AccountSubscription.live.where(account: @account).count

    go!([ { op: "plan", price: nil } ])
    assert_equal "companions", @account.reload.plan.id
    assert_equal({ CONVERSATION_PRICE => 1 }, remote)
    assert paid?(@a)
  end

  test "a timeout after Stripe applied the change: the retry replays the same key and nothing is added twice" do
    bill!(@a => CONVERSATION_PRICE)
    change = reconcile.propose([ add(@b, CONVERSATION_PRICE) ])
    @stripe.fail_next_subscription_update(applied: true)

    assert_raises(Billing::Reconcile::Uncertain) { reconcile.confirm(change, digest: change.digest) }
    assert change.reload.submitted?
    assert_not paid?(@b), "nothing is granted on the strength of a send"

    later = reconcile.propose([ add(@c, CONVERSATION_PRICE) ])

    assert change.reload.applied?, "the next proposal settled the earlier change first, by replaying it"
    assert paid?(@b)
    assert_equal [ nil, true ], @stripe.subscription_updates.map { |_, _, opts| opts[:replayed] }
    assert_equal 1, @stripe.subscription_updates.map { |_, _, opts| opts[:idempotency_key] }.uniq.size
    assert_equal({ CONVERSATION_PRICE => 2 }, remote)
    assert_equal({ CONVERSATION_PRICE => 3 }, later.wanted)
  end

  test "a timeout with nothing applied: replayed within the window, abandoned after it, never sent as new" do
    bill!(@a => CONVERSATION_PRICE)
    change = reconcile.propose([ add(@b, CONVERSATION_PRICE) ])
    @stripe.fail_next_subscription_update
    assert_raises(Billing::Reconcile::Uncertain) { reconcile.confirm(change, digest: change.digest) }
    @stripe.fail_next_subscription_update
    assert_raises(Billing::Reconcile::Uncertain) { reconcile.recover(change) }

    later = @now + 24.hours
    assert Billing::Reconcile.new(account: @account, client: @stripe, now: later).recover(change).abandoned?
    assert_equal "Stripe never applied it.", change.reload.problem
    assert_empty @stripe.subscription_updates, "Stripe never took it"
    assert_not paid?(@b)
    assert_equal({ CONVERSATION_PRICE => 1 }, remote)
  end

  test "a stale confirmation sends nothing: a wrong digest, or a bill that moved since the quote" do
    bill!(@a => CONVERSATION_PRICE)
    change = reconcile.propose([ add(@b, CONVERSATION_PRICE) ])
    assert_raises(Billing::Reconcile::QuoteChanged) { reconcile.confirm(change, digest: "not-what-was-shown") }
    assert change.reload.abandoned?

    change = reconcile.propose([ add(@b, CONVERSATION_PRICE) ])
    @stripe.price_amounts[CONVERSATION_PRICE] = 1299
    assert_raises(Billing::Reconcile::QuoteChanged) { reconcile.confirm(change, digest: change.digest) }
    assert_empty @stripe.subscription_updates
    assert_not paid?(@b)
  end

  test "one unresolved change per account: a new proposal drops an unconfirmed one" do
    bill!(@a => CONVERSATION_PRICE)
    first = reconcile.propose([ add(@b, CONVERSATION_PRICE) ])
    second = reconcile.propose([ add(@c, LIFE_PRICE) ])

    assert first.reload.abandoned?
    assert_equal [ second ], BillChange.unresolved.where(account: @account).to_a
    assert_equal first, reconcile.confirm(first, digest: first.digest), "an abandoned change is returned, never sent"
    assert first.resolved?
    assert_empty @stripe.subscription_updates
  end

  test "a bill that can't carry more on credit refuses to grow but can still shrink" do
    bill!(@a => CONVERSATION_PRICE, @b => LIFE_PRICE, status: "past_due")
    error = assert_raises(Billing::Reconcile::Refused) { reconcile.propose([ add(@c, CONVERSATION_PRICE) ]) }
    assert_match(/last payment/, error.message)
    assert reconcile.propose_end(@b).then { |change| reconcile.confirm(change, digest: change.digest) }.applied?
  end

  test "an add is refused for a resident already paid for, a retired price, and a rate the account holds no grant for" do
    bill!(@a => CONVERSATION_PRICE)
    assert_raises(Billing::AlreadySubscribed) { reconcile.propose([ add(@a, LIFE_PRICE) ]) }
    assert_raises(Billing::NotEligible) { reconcile.propose([ add(@b, LIFE_AT_COST_PRICE) ]) }
    assert_raises(Billing::NotConfigured) { reconcile.propose([ add(@b, "price_from_nowhere") ]) }
    assert_raises(Billing::Reconcile::Refused) { reconcile.propose([ { op: "end", agent_id: @b.id } ]) }
    assert_empty BillChange.unresolved.where(account: @account)
  end

  test "drift: a line no change explains grants nothing, blocks changes and is reported; rows still follow down" do
    bill!(@a => CONVERSATION_PRICE)
    @stripe.subscription("sub_acct")[:all_items] << { id: "si_stray", price: @stripe.price_object(LIFE_PRICE), quantity: 1,
      metadata: {}, current_period_end: 1.month.from_now.to_i }
    @stripe.subscription("sub_acct")[:items][:data] = @stripe.subscription("sub_acct")[:all_items]

    reports = []
    subscriber = Class.new { define_method(:report) { |error, **| reports << error } }.new
    Rails.error.subscribe(subscriber)
    sync
    assert_equal [ Billing::BillDrift ], reports.map(&:class)
    assert_match(/#{LIFE_PRICE}/, reports.sole.message)
    assert paid?(@a), "what the house granted stands while the bill lives"
    assert_equal({ CONVERSATION_PRICE => 1 }, Billing::BillSync.house_lines("sub_acct"))
    assert_raises(Billing::NotReady) { reconcile.propose([ add(@b, CONVERSATION_PRICE) ]) }

    @stripe.set_subscription_status("sub_acct", "past_due")
    sync
    assert ResidentEntitlement.find_by!(agent: @a).grace?, "down is always followed"
    @stripe.set_subscription_status("sub_acct", "active")
    sync
    assert ResidentEntitlement.find_by!(agent: @a).grace?, "up is not, while the lines aren't the house's"
    assert_equal "past_due", ResidentSubscription.find_by!(agent: @a).stripe_status

    @stripe.set_subscription_status("sub_acct", "canceled")
    sync
    assert_not paid?(@a)
    assert_equal "canceled", ResidentSubscription.find_by!(agent: @a).stripe_status
    assert_equal [ Billing::BillDrift ], reports.map(&:class).uniq
  ensure
    Rails.error.unsubscribe(subscriber) if subscriber
  end

  test "the whole bill follows the subscription: past due starts grace for every resident, ended ends every row and the plan" do
    bill!(@a => CONVERSATION_PRICE, @b => CONVERSATION_PRICE, plan: PARTNERS_PRICE)
    assert_equal "partners", @account.reload.plan.id

    @stripe.set_subscription_status("sub_acct", "past_due")
    sync
    assert_equal %w[grace grace], ResidentEntitlement.where(agent: [ @a, @b ]).pluck(:state)
    assert_equal @now, AccountSubscription.find_by!(account: @account).past_due_since

    @stripe.set_subscription_status("sub_acct", "canceled")
    sync
    assert_not paid?(@a)
    assert_not paid?(@b)
    assert_equal "companions", @account.reload.plan.id
    assert_empty Billing::Bill.new(@account).items
  end

  test "two subscriptions on one account, as before the one bill, each stay as they are" do
    bill!(@a => LIFE_AT_COST_PRICE, id: "sub_one")
    bill!(@b => LIFE_AT_COST_PRICE, id: "sub_two")
    assert paid?(@a)
    assert paid?(@b)
    assert_equal [ { price: LIFE_AT_COST_PRICE, quantity: 2 } ], Billing::Bill.new(@account).items

    change = reconcile.propose_end(@b)
    assert_equal "sub_two", change.stripe_subscription_id
    assert_equal [ { "op" => "end_bill", "agent_id" => @b.id } ], change.ops
  end

end
