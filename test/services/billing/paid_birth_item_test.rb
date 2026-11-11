require "test_helper"
require "support/fake_stripe"

# A resident created in an account that already has a live subscription is
# added to it as an item (eoXAEj slice 2b): an accepted deferred-charge
# order, born only on a verified item, linked on the item only.
class Billing::PaidBirthItemTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    Setting.instance.update!(allow_agents: true)
    @account = accounts(:personal_account)
    @account.update!(billing_required: true)
    @owner = users(:user_1)
    @first = agents(:research_assistant)
    assert_equal @account, @first.account
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    @stripe.put_payment_method("pm_visa")
    @stripe.put_customer("cus_1", default_payment_method: "pm_visa")
    parent(LIFE_PRICE)
  end

  def parent(price, status: "active")
    @stripe.put_shared_subscription(id: "sub_acct", account: @account, customer: "cus_1", status: status,
      items: [ { agent: @first, price: price, id: "si_first" } ])
    sync
  end

  def sync = Billing::SubscriptionSync.new("sub_acct", client: @stripe).call
  def paid_birth = Billing::PaidBirth.new(client: @stripe)
  def items = @stripe.subscription("sub_acct")[:all_items]
  def item_for(order) = items.find { |item| item[:metadata]["birth_order"] == order.reference }

  def start!(tier: "conversation", **overrides)
    order, secret, method = paid_birth.start!(account: @account, creator: @owner, open_beginning: false,
      tier: Billing::Tier.find!(tier),
      attributes: { name: "Aria", system_prompt: "Be curious.", model_id: "openrouter/auto" }.merge(overrides))
    assert_nil secret, "nothing is paid in the browser"
    assert_nil method
    order
  end

  def confirm!(order, digest: Billing::ItemQuote.digest(order.reload.item_quote))
    paid_birth.confirm_item!(order, digest: digest)
  end

  # The add went through at Stripe and only the answer was lost.
  def accepted_without_answer!(order)
    @stripe.fail_next_subscription_update(applied: true)
    assert_raises(Billing::PaidBirth::Uncertain) { confirm!(order) }
    assert order.reload.item_submitted_at?
  end

  test "starting pins the add and its quote on an item order; nothing is sent and nobody is born" do
    order = nil
    assert_no_difference "Agent.count" do
      order = start!
    end

    assert order.item?
    assert order.pending?
    assert_equal "sub_acct", order.stripe_subscription_id
    added = order.item_create_params["items"].last
    assert_equal({ "birth_order" => order.reference, "account_id" => @account.id.to_s, "tier" => "conversation",
                   "catalogue_price" => CONVERSATION_PRICE }, added["metadata"], "the order, never a resident")
    assert_equal "create_prorations", order.item_create_params["proration_behavior"]
    assert_equal %w[added_next currency next_at next_total parent parent_items price recurring_total],
      order.item_quote.keys.sort
    assert_empty @stripe.subscription_updates
    assert_empty @stripe.created_subscriptions, "no subscription of its own"
    assert_nil order.item_submitted_at
  end

  test "confirming adds the item once, bears the resident on it, and names the resident on the item only" do
    order = start!

    assert_difference "Agent.count", 1 do
      confirm!(order)
    end

    order.reload
    assert order.born?
    add, link = @stripe.subscription_updates
    assert_equal "souls-house-birth-item-#{order.reference}", add[2][:idempotency_key]
    assert_equal [ { id: order.stripe_subscription_item_id, metadata: { agent_id: order.agent_id.to_s } } ], link[1][:items]
    assert_not link[1].key?(:metadata), "the subscription itself names no resident"
    assert_equal order.agent_id.to_s, item_for(order)[:metadata]["agent_id"]
    row = ResidentSubscription.find_by!(agent: order.agent)
    assert_equal [ "sub_acct", order.stripe_subscription_item_id, "conversation" ],
      [ row.stripe_subscription_id, row.stripe_subscription_item_id, row.tier ]
    assert ResidentEntitlement.find_by!(agent: order.agent).active?
    assert ResidentEntitlement.find_by!(agent: @first).active?
    assert_equal({}, order.birth_attributes)
  end

  test "a second resident on a taken tier is added with an inline copy of the catalogue price" do
    order = start!(tier: "life")
    added = order.item_create_params["items"].last
    assert_nil added["price"]
    assert_equal 4999, added["price_data"]["unit_amount"]

    confirm!(order)
    assert_equal [ "life", "standard" ], ResidentSubscription.find_by!(agent: order.reload.agent).then { [ _1.tier, _1.rate ] }
  end

  test "a lost answer is finished by the webhook, without the browser" do
    order = start!
    accepted_without_answer!(order)

    assert_difference "Agent.count", 1 do
      sync
    end
    order.reload
    assert order.born?
    assert_equal item_for(order)[:id], order.stripe_subscription_item_id
    assert_equal order.agent_id.to_s, item_for(order)[:metadata]["agent_id"]

    # The browser comes back: nothing more is sent or born.
    sent = @stripe.subscription_updates.size
    assert_no_difference "Agent.count" do
      assert_equal({ accepted: true }, paid_birth.payment(order))
      confirm!(order)
      sync
    end
    assert_equal sent, @stripe.subscription_updates.size
  end

  test "a lost answer is replayed under the same key by the browser, and the item is added once" do
    order = start!
    accepted_without_answer!(order)

    assert_equal({ accepted: true }, paid_birth.payment(order))

    assert order.reload.born?
    keys = @stripe.subscription_updates.map { |_id, _params, opts| opts[:idempotency_key] }
    assert_equal [ "souls-house-birth-item-#{order.reference}" ] * 2, keys.first(2)
    assert @stripe.subscription_updates.second[2][:replayed]
    assert_equal 2, items.size
  end

  test "a sync that rolls back completes nothing" do
    order = start!
    accepted_without_answer!(order)

    sent = @stripe.subscription_updates.size
    assert_no_difference "Agent.count" do
      ApplicationRecord.transaction do
        sync
        raise ActiveRecord::Rollback
      end
    end
    assert order.reload.pending?
    # A completion inside the doomed transaction would have told Stripe about
    # a resident the rollback then erased.
    assert_equal sent, @stripe.subscription_updates.size
    assert_nil item_for(order)[:metadata]["agent_id"]
  end

  test "the browser and the webhook both completing it bear one resident" do
    order = start!
    accepted_without_answer!(order)

    assert_difference "Agent.count", 1 do
      sync
      paid_birth.complete!(order)
      paid_birth.complete!(order)
      sync
    end
    assert_equal 1, ResidentSubscription.where(stripe_subscription_id: "sub_acct", agent: order.reload.agent).count
  end

  test "a parent that stops carrying residents after acceptance: kept, needs attention, born once it carries again" do
    order = start!
    accepted_without_answer!(order)
    @stripe.set_subscription_status("sub_acct", "past_due")

    assert_no_difference "Agent.count" do
      sync
    end
    order.reload
    assert order.failed?, "needs attention"
    assert_match "past due", order.last_error
    assert_equal "Aria", order.resident_name, "the draft is kept"
    assert_empty @stripe.cancelled_subscriptions, "the account's subscription is never cancelled"
    assert_equal 2, items.size, "the accepted item stays; nothing is re-added"

    @stripe.set_subscription_status("sub_acct", "active")
    assert_difference "Agent.count", 1 do
      sync
    end
    assert order.reload.born?
  end

  test "a birth that fails with no browser is kept for attention and retried by the next webhook" do
    order = start!
    accepted_without_answer!(order)
    Setting.instance.update!(new_residents_on_vm: true, vm_resident_limit: 0)

    assert_no_difference "Agent.count" do
      sync
    end
    order.reload
    assert order.failed?
    assert_equal "Aria", order.resident_name

    Setting.instance.update!(new_residents_on_vm: false)
    assert_difference "Agent.count", 1 do
      sync
    end
    assert order.reload.born?
  end

  test "a quote that moved before sending is re-pinned and shown again; nothing is sent" do
    order = start!
    seen = order.item_quote
    @stripe.price_amounts[CONVERSATION_PRICE] = 9_900

    assert_raises(Billing::PaidBirth::QuoteChanged) { confirm!(order, digest: Billing::ItemQuote.digest(seen)) }
    assert_empty @stripe.subscription_updates
    assert_nil order.reload.item_submitted_at
    assert_not_equal seen, order.item_quote

    assert_raises(Billing::PaidBirth::QuoteChanged) { confirm!(order, digest: "0" * 64) }
    assert_difference("Agent.count", 1) { confirm!(order) }
  end

  test "the draft and the offer are checked again before anything is sent" do
    order = start!
    Setting.instance.update!(new_residents_on_vm: true, vm_resident_limit: 0)
    assert_raises(Agents::HostedProvisioning::ConfigurationError, Billing::PaidBirth::Refused) { confirm!(order) }
    assert_empty @stripe.subscription_updates
  end

  test "the receipt is more than the reference" do
    order = start!
    accepted_without_answer!(order)

    # Another resident's name on the order's item: never overwritten, never born on.
    item_for(order)[:metadata]["agent_id"] = agents(:code_reviewer).id.to_s
    assert_no_difference "Agent.count" do
      assert_raises(Billing::InvalidSubscription) { paid_birth.complete!(order) }
    end
    assert_equal agents(:code_reviewer).id.to_s, item_for(order)[:metadata]["agent_id"]

    # A price that isn't the order's offer.
    item_for(order)[:metadata].delete("agent_id")
    item_for(order)[:price] = @stripe.price_object(WORK_PRICE)
    assert_raises(Billing::InvalidSubscription) { paid_birth.complete!(order) }

    # Two items naming one order.
    item_for(order)[:price] = @stripe.price_object(CONVERSATION_PRICE)
    twin = item_for(order).deep_dup.merge(id: "si_twin", price: @stripe.inline_price(CONVERSATION_PRICE))
    items << twin
    @stripe.subscription("sub_acct")[:items][:data] << twin
    assert_raises(Billing::InvalidSubscription) { paid_birth.complete!(order) }
    assert order.reload.pending?
  end

  test "the sweeper drops an unsent item order, and never drops or cancels a sent one" do
    unsent = start!
    unsent.update_columns(expires_at: 1.minute.ago)
    paid_birth.abandon_expired!(unsent)
    assert unsent.reload.abandoned?

    sent = start!(name: "Bea")
    accepted_without_answer!(sent)
    sent.update_columns(expires_at: 1.minute.ago)
    assert_difference("Agent.count", 1) { paid_birth.abandon_expired!(sent) }
    assert sent.reload.born?
    assert_empty @stripe.cancelled_subscriptions
  end

  test "asking for another resident while one is accepted finishes it and adds nothing more" do
    order = start!
    accepted_without_answer!(order)

    error = assert_raises(Billing::PaidBirth::Refused) { start!(name: "Bea") }
    assert_match "already on the account's bill", error.message
    assert_no_match(/payment|paid/i, error.message)
    assert order.reload.born?
    assert_equal 2, items.size
  end

  test "an unsent quote is dropped when the owner starts again" do
    first = start!
    second = start!(name: "Bea")
    assert first.reload.abandoned?
    assert second.pending?
    assert_empty @stripe.subscription_updates
  end

  test "a parent that can't carry a resident on credit is refused before an order is made" do
    parent(LIFE_PRICE, status: "trialing")
    assert_raises(Billing::ItemQuote::Refused) { start! }
    assert_equal 0, ResidentBirthOrder.count
  end

  test "an account without a live subscription still opens a subscription of its own" do
    @stripe.set_subscription_status("sub_acct", "canceled")
    sync
    order, secret, = paid_birth.start!(account: @account, creator: @owner, open_beginning: false,
      tier: Billing::Tier.find!("conversation"), attributes: { name: "Aria", system_prompt: "Be curious." })
    assert_not order.item?
    assert secret.present?
    assert_equal 1, @stripe.created_subscriptions.size
  end

  test "an order needing attention is brought back by the sweep alone, with no webhook and no browser" do
    order = start!
    accepted_without_answer!(order)
    @stripe.set_subscription_status("sub_acct", "past_due")
    paid_birth.complete!(order)
    assert order.reload.failed?

    @stripe.set_subscription_status("sub_acct", "active")
    Billing.stub(:client, @stripe) do
      assert_no_difference("Agent.count") { Billing::SweepJob.perform_now(now: order.item_submitted_at + 1.minute) }
      assert_difference("Agent.count", 1) { Billing::SweepJob.perform_now(now: 10.minutes.from_now) }
    end
    assert order.reload.born?
    assert_equal order.agent_id.to_s, item_for(order)[:metadata]["agent_id"]
  end

  test "a sent order whose answer was lost is finished by the sweep before it expires" do
    order = start!
    accepted_without_answer!(order)
    Billing.stub(:client, @stripe) do
      assert_difference("Agent.count", 1) { Billing::SweepJob.perform_now(now: 10.minutes.from_now) }
    end
    assert order.reload.born?
  end

  test "the sweep settles a sent order whose update never reached Stripe, by replaying it under its key" do
    order = start!
    @stripe.fail_next_subscription_update(applied: false)
    assert_raises(Billing::PaidBirth::Uncertain) { confirm!(order) }
    assert_equal 1, items.size, "Stripe added nothing"

    Billing.stub(:client, @stripe) do
      assert_difference("Agent.count", 1) { Billing::SweepJob.perform_now(now: 10.minutes.from_now) }
    end
    assert order.reload.born?
    assert_equal [ "souls-house-birth-item-#{order.reference}" ],
      @stripe.subscription_updates.map { |_id, _params, opts| opts[:idempotency_key] }.uniq.first(1)
    assert_equal 2, items.size
  end

  test "expiry and confirmation share the account lock: an order being sent is never dropped" do
    order = start!
    order.update_columns(expires_at: 1.minute.from_now)
    held = Hash.new(0)
    owner = {}
    # pg_try_advisory_lock, per account and per session: re-entrant for its
    # holder, busy for anyone else.
    lock = lambda do |account, &operation|
      session = Thread.current[:billing_session] || :browser
      raise Billing::NotReady, "busy" if held[account.id].positive? && owner[account.id] != session

      owner[account.id] = session
      held[account.id] += 1
      begin
        operation.call
      ensure
        held[account.id] -= 1
      end
    end
    sweep = lambda do
      Thread.current[:billing_session] = :sweeper
      paid_birth.abandon_expired!(order.reload)
    rescue Billing::NotReady
      :busy
    ensure
      Thread.current[:billing_session] = nil
    end
    swept = nil
    original = Billing::ItemQuote.instance_method(:stale?)
    Billing::CheckoutLock.define_singleton_method(:synchronize_residents) { |account, &op| lock.call(account, &op) }
    Billing::ItemQuote.define_method(:stale?) do |*args, **kw|
      # The sweep arrives at expiry while confirm is previewing.
      swept ||= sweep.call
      original.bind_call(self, *args, **kw)
    end
    begin
      confirm!(order)
    ensure
      Billing::ItemQuote.define_method(:stale?, original)
    end

    assert_equal :busy, swept, "the sweep found the account busy"
    assert order.reload.born?, "the order being sent was not dropped"
    assert_equal 1, @stripe.subscription_updates.count { |_id, _params, opts| opts[:idempotency_key].to_s.include?("birth-item") }
  end

  test "an unsent quote past its expiry is not sent" do
    order = start!
    order.update_columns(expires_at: 1.minute.ago)
    assert_raises(Billing::PaidBirth::Refused) { confirm!(order) }
    assert order.reload.abandoned?
    assert_empty @stripe.subscription_updates
  end

  test "before the first birth the item must carry the price the order pinned, not another of the same offer" do
    @stripe.put_price("price_old_conversation", product: "prod_test_conversation", unit_amount: 1999)
    ENV["STRIPE_PRICE_CONVERSATION"] = "#{CONVERSATION_PRICE},price_old_conversation"
    order = start!
    assert_equal CONVERSATION_PRICE, order.item_create_params["items"].last["price"]
    accepted_without_answer!(order)
    item_for(order)[:price] = @stripe.price_object("price_old_conversation")

    assert_no_difference "Agent.count" do
      error = assert_raises(Billing::InvalidSubscription) { paid_birth.complete!(order) }
      assert_match "pinned", error.message
    end
  end

end
