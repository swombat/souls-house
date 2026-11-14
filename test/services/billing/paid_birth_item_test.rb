require "test_helper"
require "support/fake_stripe"

# A resident created in an account that already has a live subscription goes
# onto that bill as a bill change with a birth op: nothing charged on the
# day, born only when Stripe carries its line on a paid subscription.
class Billing::PaidBirthItemTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    Setting.instance.update!(allow_agents: true)
    @account = accounts(:personal_account)
    @account.update!(billing_required: true)
    @owner = users(:user_1)
    @first = agents(:research_assistant)
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    @stripe.put_payment_method("pm_visa")
    @stripe.put_customer("cus_1", default_payment_method: "pm_visa")
    parent(LIFE_PRICE)
  end

  def parent(price, status: "active")
    @stripe.put_shared_subscription(id: "sub_acct", account: @account, customer: "cus_1", status: status,
      items: [ { price: price, id: "si_first" } ])
    ResidentSubscription.where(agent: @first).delete_all
    row = ResidentSubscription.create!(agent: @first, account: @account, stripe_subscription_id: "sub_acct",
      tier: Billing::Offer.for_price(price).tier.id, rate: "standard", stripe_price_id: price, stripe_status: "active")
    ResidentEntitlement.for_agent!(@first).apply_subscription!(row)
    sync
  end

  def sync = Billing::BillSync.new("sub_acct", client: @stripe).call
  def paid_birth = Billing::PaidBirth.new(client: @stripe)
  def lines = Billing::BillSync.remote_lines(@stripe.subscriptions.retrieve("sub_acct"), client: @stripe)

  def start!(tier: "conversation", **overrides)
    order, secret, method = paid_birth.start!(account: @account, creator: @owner, open_beginning: false,
      tier: Billing::Tier.find!(tier),
      attributes: { name: "Aria", system_prompt: "Be curious.", model_id: "openrouter/auto" }.merge(overrides))
    assert_nil secret, "nothing is paid in the browser"
    assert_nil method
    order
  end

  def confirm!(order, digest: order.reload.bill_change.digest) = paid_birth.confirm_item!(order, digest: digest)

  # The change went through at Stripe and only the answer was lost.
  def accepted_without_answer!(order)
    @stripe.fail_next_subscription_update(applied: true)
    assert_raises(Billing::PaidBirth::Uncertain) { confirm!(order) }
    assert order.reload.sent?
  end

  test "starting proposes the change and its quote on an item order; nothing is sent and nobody is born" do
    order = nil
    assert_no_difference "Agent.count" do
      order = start!
    end

    assert order.item?
    assert order.pending?
    assert_not order.sent?
    change = order.bill_change
    assert change.proposed?
    assert_equal [ { "op" => "birth", "order" => order.reference, "price" => CONVERSATION_PRICE } ], change.ops
    assert_equal({ LIFE_PRICE => 1, CONVERSATION_PRICE => 1 }, change.wanted)
    assert_equal 2499 + 500, change.quote["added_next"]
    assert_equal({ item_quote: change.quote }, paid_birth.payment(order))
    assert_empty @stripe.subscription_updates
    assert_empty @stripe.created_subscriptions, "no subscription of its own"
  end

  test "confirming sends the change once and bears the resident on the account's bill" do
    order = start!
    assert_difference "Agent.count", 1 do
      confirm!(order)
    end

    order.reload
    assert order.born?
    assert order.bill_change.applied?
    assert_equal "Aria", order.agent.name
    assert_equal({}, order.birth_attributes)
    assert_equal [ { price: CONVERSATION_PRICE, quantity: 1 } ], @stripe.subscription_updates.sole[1][:items]
    assert ResidentEntitlement.paid_for?(order.agent)
    assert_equal "sub_acct", ResidentSubscription.find_by!(agent: order.agent).stripe_subscription_id
    assert_equal({ accepted: true }, paid_birth.payment(order))

    assert_no_difference "Agent.count" do
      confirm!(order)
      sync
    end
    assert_equal 1, @stripe.subscription_updates.size
  end

  test "a second resident at a price the bill already carries raises that line's quantity" do
    order = start!(tier: "life")
    confirm!(order)

    assert_equal [ { id: "si_first", quantity: 2 } ], @stripe.subscription_updates.sole[1][:items]
    assert_equal({ LIFE_PRICE => 2 }, lines)
    assert order.reload.born?
  end

  test "a lost answer is finished by the webhook alone, and by the browser replaying the same key, once" do
    order = start!
    accepted_without_answer!(order)
    assert_not order.reload.born?, "nobody is born on the strength of a send"

    assert_difference "Agent.count", 1 do
      sync
    end
    assert order.reload.born?

    assert_no_difference "Agent.count" do
      confirm!(order)
    end
    assert_equal 1, @stripe.subscription_updates.size
  end

  test "a lost answer with no webhook is replayed by the browser under the same key" do
    order = start!
    accepted_without_answer!(order)

    assert_difference "Agent.count", 1 do
      assert_equal({ accepted: true }, paid_birth.payment(order))
    end
    assert_equal [ nil, true ], @stripe.subscription_updates.map { |_, _, opts| opts[:replayed] }
    assert_equal({ LIFE_PRICE => 1, CONVERSATION_PRICE => 1 }, lines)
  end

  test "a bill that stops being paid after the change was sent: kept, needs attention, born once it is paid again" do
    order = start!
    accepted_without_answer!(order)
    @stripe.set_subscription_status("sub_acct", "past_due")

    assert_no_difference "Agent.count" do
      paid_birth.resume_item!(order)
    end
    order.reload
    assert order.failed?
    assert_match(/can't be created yet/, order.last_error)
    assert order.bill_change.submitted?, "its line is on the bill; the change waits"
    assert_equal "Aria", order.resident_name, "the draft is kept"

    @stripe.set_subscription_status("sub_acct", "active")
    assert_difference "Agent.count", 1 do
      Billing.stub(:client, @stripe) { Billing::SweepJob.perform_now(now: 10.minutes.from_now) }
    end
    assert order.reload.born?
    assert ResidentEntitlement.paid_for?(order.agent)
  end

  test "a bill whose payments were paused after the change was sent bears nobody until they resume" do
    order = start!
    accepted_without_answer!(order)
    @stripe.subscription("sub_acct")[:pause_collection] = { behavior: "void" }

    assert_no_difference "Agent.count" do
      paid_birth.resume_item!(order)
    end
    assert order.reload.failed?
    assert order.bill_change.submitted?, "its line is on the bill; the change waits"

    @stripe.subscription("sub_acct")[:pause_collection] = nil
    assert_difference "Agent.count", 1 do
      Billing.stub(:client, @stripe) { Billing::SweepJob.perform_now(now: 10.minutes.from_now) }
    end
    assert order.reload.born?
  end

  test "a birth that fails rolls the landing back, is kept for attention, and is retried" do
    order = start!
    Setting.instance.update!(new_residents_on_vm: true, vm_resident_limit: 0)

    assert_no_difference "Agent.count" do
      confirm!(order)
    end
    order.reload
    assert order.failed?
    assert order.bill_change.submitted?
    assert_equal({ LIFE_PRICE => 1, CONVERSATION_PRICE => 1 }, lines, "Stripe took the line")
    assert_equal({ LIFE_PRICE => 1 }, Billing::BillSync.house_lines("sub_acct"), "the house holds nothing for it yet")

    Setting.instance.update!(new_residents_on_vm: false)
    assert_difference "Agent.count", 1 do
      paid_birth.resume_item!(order)
    end
    assert order.reload.born?
    assert_equal lines, Billing::BillSync.house_lines("sub_acct")
  end

  test "a quote that moved before sending is proposed again and shown again; nothing is sent" do
    order = start!
    stale = order.bill_change
    @stripe.price_amounts[CONVERSATION_PRICE] = 2999

    error = assert_raises(Billing::PaidBirth::QuoteChanged) { confirm!(order) }
    assert_equal order, error.order
    order.reload
    assert stale.reload.abandoned?
    assert order.bill_change.proposed?
    assert_not_equal stale, order.bill_change
    assert_equal 2999 + 500, order.bill_change.quote["added_next"]
    assert_empty @stripe.subscription_updates

    confirm!(order)
    assert order.reload.born?
  end

  test "the sweeper drops an unsent order past its time and finishes a sent one" do
    unsent = start!
    travel_to 24.hours.from_now do
      error = assert_raises(Billing::PaidBirth::Refused) { confirm!(unsent) }
      assert_match(/expired/, error.message)
    end
    assert unsent.reload.abandoned?
    assert unsent.bill_change.abandoned?
    assert_empty @stripe.subscription_updates

    sent = start!(name: "Bea")
    accepted_without_answer!(sent)
    assert_difference "Agent.count", 1 do
      Billing.stub(:client, @stripe) { Billing::SweepJob.perform_now(now: 10.minutes.from_now) }
    end
    assert sent.reload.born?
  end

  test "starting again drops an unsent order; while one is sent, the next request finishes it and adds nothing more" do
    first = start!
    second = start!(name: "Bea")
    assert first.reload.abandoned?
    assert first.bill_change.abandoned?

    accepted_without_answer!(second)
    error = assert_raises(Billing::PaidBirth::Refused) { start!(name: "Cy") }
    assert_match(/already on the account's bill/, error.message)
    assert second.reload.born?
    assert_equal 1, @stripe.subscription_updates.count { |_, _, opts| !opts[:replayed] }
    assert_equal 0, ResidentBirthOrder.where(state: "pending").count
  end

  test "a bill that can't carry a resident on credit is refused before an order is made" do
    @stripe.set_subscription_status("sub_acct", "past_due")
    sync
    error = assert_raises(Billing::PaidBirth::Refused) { start! }
    assert_match(/last payment/, error.message)
    assert_equal 0, ResidentBirthOrder.count
    assert_equal 0, BillChange.count
  end

  test "an account without a live subscription still opens a subscription of its own" do
    ResidentSubscription.where(account: @account).update_all(stripe_status: "canceled")
    order, secret, = paid_birth.start!(account: @account, creator: @owner, open_beginning: false,
      tier: Billing::Tier.find!("conversation"), attributes: { name: "Aria", system_prompt: "Be curious." })

    assert_not order.item?
    assert secret.present?
    assert_equal 1, @stripe.created_subscriptions.size
  end

end
