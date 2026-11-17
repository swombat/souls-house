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

  test "the plan is a line on the same bill: changed, and never bought or dropped apart from its resident" do
    bill!(@a => CONVERSATION_INCLUDED_PRICE, plan: COMPANIONS_PRICE)
    go!([ { op: "plan", price: PARTNERS_PRICE } ])
    assert_equal "partners", @account.reload.plan.id
    assert_equal({ CONVERSATION_INCLUDED_PRICE => 1, PARTNERS_PRICE => 1 }, remote)

    go!([ { op: "plan", price: COLLEAGUES_PRICE } ])
    assert_equal "colleagues", @account.reload.plan.id
    assert_equal({ CONVERSATION_INCLUDED_PRICE => 1, COLLEAGUES_PRICE => 1 }, remote)
    assert_equal 1, AccountSubscription.live.where(account: @account).count

    error = assert_raises(Billing::Reconcile::Refused) { reconcile.propose([ { op: "plan", price: nil } ]) }
    assert_match(/stays while its included resident/, error.message)
    assert paid?(@a)
  end

  test "a bill with no plan line gets none by itself: a plan alone is refused, and a resident added is at its size" do
    bill!(@a => LIFE_AT_COST_PRICE)
    error = assert_raises(Billing::Reconcile::Refused) { reconcile.propose([ { op: "plan", price: PARTNERS_PRICE } ]) }
    assert_match(/bought with the resident it includes/, error.message)
    assert_equal [ { op: "add", agent_id: @b.id, price: CONVERSATION_PRICE } ],
      Billing::Reconcile.add_ops(@account, @b, Billing::Tier.find!("conversation").offer)
  end

  test "a resident added to a bill with a plan is at its size; the plan's own is the included one" do
    bill!(@a => CONVERSATION_INCLUDED_PRICE, plan: COMPANIONS_PRICE)
    assert_equal [ { op: "add", agent_id: @b.id, price: LIFE_PRICE } ],
      Billing::Reconcile.add_ops(@account, @b, Billing::Tier.find!("life").offer)
    error = assert_raises(Billing::Reconcile::Refused) { reconcile.propose([ add(@b, LIFE_INCLUDED_PRICE) ]) }
    assert_match(/already has its plan's included resident/, error.message)
    go!([ add(@b, LIFE_PRICE) ])
    assert_equal({ CONVERSATION_INCLUDED_PRICE => 1, COMPANIONS_PRICE => 1, LIFE_PRICE => 1 }, remote)
  end

  test "ending the included resident makes the oldest one left the included one, in the same change" do
    bill!(@a => CONVERSATION_INCLUDED_PRICE, @b => LIFE_PRICE, @c => CONVERSATION_PRICE, plan: PARTNERS_PRICE)
    ResidentSubscription.find_by!(agent: @c).update_columns(created_at: 1.day.from_now)
    change = reconcile.propose_end(@a)
    assert_equal [ { "op" => "end", "agent_id" => @a.id },
                   { "op" => "promote", "agent_id" => @b.id, "price" => LIFE_INCLUDED_PRICE } ], change.ops
    # The plan already paid for a Small: the Medium left drops from $39.99 to $30.
    assert_equal 2999 + 3000 + 2499, change.quote["recurring_total"], "Partners, the Medium included, the Small at its size"
    reconcile.confirm(change, digest: change.digest)

    assert_equal({ PARTNERS_PRICE => 1, LIFE_INCLUDED_PRICE => 1, CONVERSATION_PRICE => 1 }, remote)
    assert_equal %w[life included], ResidentSubscription.live.find_by!(agent: @b).then { |row| [ row.tier, row.rate ] }
    assert_equal "included", ResidentEntitlement.find_by!(agent: @b).rate
    assert_not paid?(@a)
    assert paid?(@b)
    assert_equal "partners", @account.reload.plan.id
  end

  test "ending the included resident with only at cost left takes the plan line off with it" do
    grant!("at_cost")
    bill!(@a => CONVERSATION_INCLUDED_PRICE, @b => LIFE_AT_COST_PRICE, plan: COMPANIONS_PRICE)
    change = reconcile.propose_end(@a)
    assert_equal [ { "op" => "end", "agent_id" => @a.id }, { "op" => "plan" } ], change.ops
    reconcile.confirm(change, digest: change.digest)

    assert_equal({ LIFE_AT_COST_PRICE => 1 }, remote)
    assert_empty AccountSubscription.live.where(account: @account)
    assert paid?(@b)
  end

  test "ending the only resident of a bill with a plan ends the whole bill, plan and all" do
    bill!(@a => CONVERSATION_INCLUDED_PRICE, plan: COMPANIONS_PRICE)
    change = reconcile.propose_end(@a)
    assert_equal [ { "op" => "end_bill", "agent_id" => @a.id } ], change.ops
    assert change.quote["ends"]
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
    assert_raises(Billing::Reconcile::QuoteChanged, "an abandoned change is never sent and never reported as done") do
      reconcile.confirm(first, digest: first.digest)
    end
    assert first.reload.abandoned?
    assert second.reload.proposed?
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

  test "a hosted Checkout still open for the resident is closed before it joins the bill, so it can't be paid for twice" do
    Billing::CheckoutLock.stub(:synchronize, ->(_agent, &operation) { operation.call }) do
      Billing::Checkout.new(agent: @b, tier: Billing::Tier.find!("conversation"), client: @stripe,
        success_url: "https://house.test/ok", cancel_url: "https://house.test/no").url
    end
    assert_equal [ "open" ], @stripe.session_states.values.map { |session| session[:status] }
    assert BillingCheckoutAttempt.unresolved.exists?(agent: @b)

    bill!(@a => LIFE_PRICE)
    go!([ add(@b, CONVERSATION_PRICE) ])

    assert_equal [ "expired" ], @stripe.session_states.values.map { |session| session[:status] }
    assert_not BillingCheckoutAttempt.unresolved.exists?(agent: @b)
    assert paid?(@b)
    assert_empty @stripe.created_subscriptions
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
    assert_empty ResidentSubscription.live.where(account: @account)
    assert_empty AccountSubscription.live.where(account: @account)
  end

  test "a quote is only confirmed while the house would still propose it: a grant withdrawn since refuses it" do
    bill!(@a => CONVERSATION_PRICE)
    grant = BillingCode.redeem!(code: BillingCode.create!(code: "PEPE", effect: "at_cost", created_by: users(:site_admin_user)).code,
      account: @account, by: users(:site_admin_user))
    change = reconcile.propose([ add(@b, CONVERSATION_AT_COST_PRICE) ])
    grant.update!(withdrawn_at: @now)

    assert_raises(Billing::Reconcile::QuoteChanged) { reconcile.confirm(change, digest: change.digest) }
    assert change.reload.abandoned?
    assert_empty @stripe.subscription_updates
    assert_not paid?(@b)
  end

  test "a bill that went unpaid and is paid again brings its residents and plan back" do
    bill!(@a => CONVERSATION_PRICE, @b => CONVERSATION_PRICE, plan: PARTNERS_PRICE)
    @stripe.set_subscription_status("sub_acct", "unpaid")
    sync
    assert_not paid?(@a)
    assert_equal "companions", @account.reload.plan.id

    @stripe.set_subscription_status("sub_acct", "active")
    sync
    assert paid?(@a)
    assert paid?(@b)
    assert_equal "partners", @account.reload.plan.id
    assert_equal({ CONVERSATION_PRICE => 2, PARTNERS_PRICE => 1 }, Billing::BillSync.house_lines("sub_acct"))
  end

  test "an unpaid row is not brought back when its resident is paid for elsewhere since: that is drift" do
    bill!(@a => CONVERSATION_PRICE, @b => CONVERSATION_PRICE)
    @stripe.set_subscription_status("sub_acct", "unpaid")
    sync
    bill!(@b => LIFE_PRICE, id: "sub_new")

    @stripe.set_subscription_status("sub_acct", "active")
    reports = []
    subscriber = Class.new { define_method(:report) { |error, **| reports << error } }.new
    Rails.error.subscribe(subscriber)
    begin
      sync
    ensure
      Rails.error.unsubscribe(subscriber)
    end
    assert_equal [ Billing::BillDrift ], reports.map(&:class).uniq
    assert_not paid?(@a), "nothing is granted on a bill the house can't account for"
    assert_equal %w[sub_new], ResidentSubscription.live.where(agent: @b).pluck(:stripe_subscription_id)
  end

  test "two subscriptions on one account, as before the one bill, each stay as they are" do
    bill!(@a => LIFE_AT_COST_PRICE, id: "sub_one")
    bill!(@b => LIFE_AT_COST_PRICE, id: "sub_two")
    assert paid?(@a)
    assert paid?(@b)
    assert_equal [ { LIFE_AT_COST_PRICE => 1 } ] * 2, %w[sub_one sub_two].map { |id| Billing::BillSync.house_lines(id) }

    change = reconcile.propose_end(@b)
    assert_equal "sub_two", change.stripe_subscription_id
    assert_equal [ { "op" => "end_bill", "agent_id" => @b.id } ], change.ops
  end

  def grant!(effect)
    BillingCode.redeem!(code: BillingCode.create!(code: "G-#{SecureRandom.hex(4)}", effect:, created_by: users(:site_admin_user)).code,
      account: @account, by: users(:site_admin_user))
  end

  test "a grant for one size is no grant for another: a resident can't be resized past it" do
    grant!("at_cost:conversation")
    bill!(@a => CONVERSATION_AT_COST_PRICE)

    assert_raises(Billing::NotEligible) { reconcile.propose([ { op: "resize", agent_id: @a.id, price: LIFE_AT_COST_PRICE } ]) }

    wide = grant!("at_cost")
    change = reconcile.propose([ { op: "resize", agent_id: @a.id, price: LIFE_AT_COST_PRICE } ])
    wide.withdraw!(by: users(:site_admin_user))
    assert_raises(Billing::Reconcile::QuoteChanged) { reconcile.confirm(change, digest: change.digest) }
    assert_empty @stripe.subscription_updates
    assert_equal({ CONVERSATION_AT_COST_PRICE => 1 }, remote)
  end

  test "a plan the account holds free is not bought, nor a quote for it confirmed" do
    bill!(@a => CONVERSATION_INCLUDED_PRICE, plan: COMPANIONS_PRICE)
    change = reconcile.propose([ { op: "plan", price: PARTNERS_PRICE } ])
    # A site admin's grant (a code would be refused while a plan is paid for:
    # BillingCode#plan_refusal).
    @account.update!(granted_plan: "partners")

    assert_raises(Billing::Reconcile::QuoteChanged) { reconcile.confirm(change, digest: change.digest) }
    assert_empty @stripe.subscription_updates
    assert_raises(Billing::Reconcile::Refused) { reconcile.propose([ { op: "plan", price: PARTNERS_PRICE } ]) }
    assert reconcile.propose([ { op: "plan", price: COLLEAGUES_PRICE } ]), "a higher plan can still be bought"
  end


  # The one account paying on 17 Nov 2026, as it stands: an at-cost code, a
  # site grant of Colleagues, a Medium and a Large at the Hetzner at-cost
  # rate on one subscription, no plan line. "No existing paying account's
  # monthly total changes" (eRyZBY), held as a test.
  test "the account paying at cost keeps exactly its lines and total: no plan line, no included resident, ever" do
    grant!("at_cost")
    @account.update!(granted_plan: "colleagues")
    bill!(@a => LIFE_AT_COST_HETZNER_PRICE, @b => WORK_AT_COST_HETZNER_PRICE)
    before = remote
    assert_equal({ LIFE_AT_COST_HETZNER_PRICE => 1, WORK_AT_COST_HETZNER_PRICE => 1 }, before)
    assert_equal 1100 + 2000, before.sum { |price, quantity| @stripe.price_object(price)[:unit_amount] * quantity }

    sync
    assert_equal before, remote, "bringing the bill in changes nothing"
    assert_equal before, Billing::BillSync.house_lines("sub_acct")
    assert_empty AccountSubscription.where(account: @account)
    assert_nil @account.reload.plan_to_pay_for, "the plan is given: nothing to pay for it"
    assert_not Billing::Included.available?(@account), "an at-cost residence, no free residence"
    assert_equal %w[at_cost_hetzner at_cost_hetzner], ResidentSubscription.live.where(account: @account).pluck(:rate)

    # A resident bought at the catalogue price is at its size, and brings no plan line.
    assert_equal [ { op: "add", agent_id: @c.id, price: CONVERSATION_PRICE } ],
      Billing::Reconcile.add_ops(@account, @c, Billing::Tier.find!("conversation").offer)
    assert_raises(Billing::Reconcile::Refused) { reconcile.propose([ { op: "plan", price: COLLEAGUES_PRICE } ]) }
    assert_raises(Billing::Reconcile::Refused) { reconcile.propose([ add(@c, CONVERSATION_INCLUDED_PRICE) ]) }
    assert_equal before, remote, "and nothing was sent"
    assert_empty @stripe.subscription_updates

    # Control: it is the at-cost code that holds this. Without it, the same
    # account's given plan would include a resident.
    BillingCodeRedemption.where(account: @account).find_each { |redemption| redemption.withdraw!(by: users(:site_admin_user)) }
    assert Billing::Included.available?(@account.reload)
  end

end
