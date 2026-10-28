require "test_helper"
require "support/fake_stripe"

class Billing::PaidBirthTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    Setting.instance.update!(allow_agents: true)
    @account = accounts(:personal_account)
    @account.update!(billing_required: true)
    @owner = users(:user_1)
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    @stripe.put_payment_method("pm_visa")
    @stripe.put_customer("cus_1", default_payment_method: "pm_visa")
    @tier = Billing::Tier.find!("conversation")
  end

  def paid_birth = Billing::PaidBirth.new(client: @stripe)

  def start!(**overrides)
    paid_birth.start!(account: @account, creator: @owner, open_beginning: false, tier: @tier,
      attributes: { name: "Aria", system_prompt: "Be curious.", model_id: "openrouter/auto" }.merge(overrides))
  end

  test "starting records the draft and opens the plan's first payment, creating no resident" do
    order = nil
    assert_no_difference [ "Agent.count", "HouseInferenceGrant.count" ] do
      order, client_secret, payment_method = start!
      assert_equal "pi_sub_new_1_secret", client_secret
      assert_equal "pm_visa", payment_method
    end

    assert order.pending?
    assert_equal "sub_new_1", order.stripe_subscription_id
    assert_equal "Aria", order.resident_name
    params, opts = @stripe.created_subscriptions.sole
    assert_equal "cus_1", params[:customer]
    assert_equal [ { price: CONVERSATION_PRICE } ], params[:items]
    assert_equal "pm_visa", params[:default_payment_method]
    assert_equal "default_incomplete", params[:payment_behavior]
    assert_equal({ enabled: true }, params[:automatic_tax])
    assert_equal order.reference, params[:metadata][:birth_order]
    assert_nil params[:metadata][:agent_id]
    assert_equal "souls-house-birth-order-#{order.reference}", opts[:idempotency_key]
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, order.reference)
  end

  test "only an account that pays, its owner, a card and a complete draft can start" do
    @account.update!(billing_required: false)
    assert_raises(Billing::PaidBirth::Refused) { start! }
    @account.update!(billing_required: true)

    assert_raises(Billing::PaidBirth::Refused) do
      paid_birth.start!(account: @account, creator: users(:regular_user), open_beginning: false, tier: @tier,
        attributes: { name: "Aria", system_prompt: "x" })
    end
    assert_raises(Billing::PaidBirth::Refused) { start!(name: " ") }
    assert_raises(Billing::PaidBirth::Refused) { start!(system_prompt: "") }

    @stripe.put_customer("cus_1", default_payment_method: nil)
    assert_raises(Billing::PaidBirth::Refused) { start! }
    assert_empty @stripe.created_subscriptions
    assert_equal 0, ResidentBirthOrder.count
  end

  test "nothing is born while the first payment is unpaid" do
    order, = start!
    assert_no_difference "Agent.count" do
      paid_birth.complete!(order)
    end
    assert order.reload.pending?
  end

  test "once paid, the resident is born on the plan, without the free grant, and the draft is cleared" do
    order, = start!
    @stripe.set_subscription_status("sub_new_1", "active")

    assert_difference "Agent.count", 1 do
      assert_no_difference "HouseInferenceGrant.count" do
        paid_birth.complete!(order)
      end
    end

    order.reload
    agent = order.agent
    assert order.born?
    assert_equal({}, order.birth_attributes)
    assert_equal "Aria", agent.name
    assert_equal @account, agent.account
    assert_equal agent.id.to_s, @stripe.subscription("sub_new_1")[:metadata]["agent_id"]
    entitlement = ResidentEntitlement.find_by!(agent: agent)
    assert entitlement.active?
    assert_equal "conversation", entitlement.tier
    assert ResidentEntitlement.paid_for?(agent)
  end

  test "the browser and the webhook can both complete it; the resident is born once" do
    order, = start!
    @stripe.set_subscription_status("sub_new_1", "active")

    assert_difference "Agent.count", 1 do
      Billing::SubscriptionSync.new("sub_new_1", client: @stripe).call
      paid_birth.complete!(order)
      Billing::SubscriptionSync.new("sub_new_1", client: @stripe).call
    end
    assert order.reload.born?
    assert_equal 1, ResidentSubscription.where(stripe_subscription_id: "sub_new_1").count
  end

  test "a webhook for an unpaid order changes nothing" do
    start!
    assert_nil Billing::SubscriptionSync.new("sub_new_1", client: @stripe).call
    assert_equal 0, ResidentSubscription.count
  end

  test "a birth that fails after payment keeps the order and its draft, and says so" do
    order, = start!
    @stripe.set_subscription_status("sub_new_1", "active")
    Setting.instance.update!(new_residents_on_vm: true, vm_resident_limit: 0)

    assert_no_difference "Agent.count" do
      assert_raises(Agents::HostedProvisioning::ConfigurationError) { paid_birth.complete!(order) }
    end
    order.reload
    assert order.failed?
    assert_equal "Aria", order.resident_name
    assert_predicate order.last_error, :present?

    Setting.instance.update!(new_residents_on_vm: false)
    assert_difference "Agent.count", 1 do
      paid_birth.complete!(order)
    end
    assert order.reload.born?
  end

  test "asking again replaces an earlier unpaid order and cancels its subscription" do
    first, = start!
    second, = start!(name: "Bea")

    assert first.reload.abandoned?
    assert_equal({}, first.birth_attributes)
    assert_equal [ "sub_new_1" ], @stripe.cancelled_subscriptions
    assert second.pending?
  end

  test "paying again uses the card now on the account" do
    order, = start!
    @stripe.put_payment_method("pm_mastercard", brand: "mastercard", last4: "4444")
    @stripe.put_customer("cus_1", default_payment_method: "pm_mastercard")

    result = paid_birth.payment(order)

    assert_equal "pi_sub_new_1_secret", result[:client_secret]
    assert_equal "pm_mastercard", result[:payment_method_id]
    assert_equal "pm_mastercard", @stripe.subscription("sub_new_1")[:default_payment_method]
  end

  test "the sweeper abandons an expired unpaid order, but bears one paid at the last moment" do
    unpaid, = start!
    unpaid.update!(expires_at: 1.minute.ago)
    paid_birth.abandon_expired!(unpaid)
    assert unpaid.reload.abandoned?
    assert_equal({}, unpaid.birth_attributes)
    assert_includes @stripe.cancelled_subscriptions, "sub_new_1"

    late, = start!(name: "Cai")
    late.update!(expires_at: 1.minute.ago)
    @stripe.set_subscription_status(late.stripe_subscription_id, "active")
    assert_difference "Agent.count", 1 do
      paid_birth.abandon_expired!(late)
    end
    assert late.reload.born?
  end

  test "an uncertain answer opening the subscription keeps the order and its draft; paying again finds it" do
    @stripe.fail_next_subscription_create(created: true)
    assert_raises(Billing::PaidBirth::Uncertain) { start! }
    order = ResidentBirthOrder.sole
    assert order.pending?
    assert_equal "Aria", order.resident_name
    assert_nil order.stripe_subscription_id

    result = paid_birth.payment(order)
    assert_equal "pi_sub_new_1_secret", result[:client_secret]
    assert_equal "sub_new_1", order.reload.stripe_subscription_id
    assert_equal 1, @stripe.created_subscriptions.size, "the subscription Stripe made is found, not made again"
  end

  test "an uncertain answer where Stripe made nothing opens the subscription on retry" do
    @stripe.fail_next_subscription_create(created: false)
    assert_raises(Billing::PaidBirth::Uncertain) { start! }
    order = ResidentBirthOrder.sole

    result = paid_birth.payment(order)
    assert_equal "sub_new_1", order.reload.stripe_subscription_id
    assert_equal "pi_sub_new_1_secret", result[:client_secret]
    assert_equal 1, @stripe.created_subscriptions.size
  end

  test "the webhook teaches an order the subscription id it never heard back" do
    @stripe.fail_next_subscription_create(created: true)
    assert_raises(Billing::PaidBirth::Uncertain) { start! }
    @stripe.set_subscription_status("sub_new_1", "active")

    assert_difference "Agent.count", 1 do
      Billing::SubscriptionSync.new("sub_new_1", client: @stripe).call
    end
    order = ResidentBirthOrder.sole
    assert order.born?
    assert_equal "sub_new_1", order.stripe_subscription_id
    assert ResidentEntitlement.find_by!(agent: order.agent).active?
  end

  # Production's order 1 met an idempotency key spent by another environment's
  # order 1 in the shared Stripe test account (oewbQY 2026-10-25).
  test "an order is named at Stripe by a random reference, never by an id another environment shares" do
    @stripe.fail_next_subscription_create(created: false)
    assert_raises(Billing::PaidBirth::Uncertain) { start! }
    order = ResidentBirthOrder.sole
    other = ResidentBirthOrder.create!(account: @account, creator: @owner, tier: "conversation", state: "abandoned")
    assert_not_equal order.reference, other.reference

    # Another environment's paid subscriptions: one naming this order's id the
    # old way, one naming a different order reference.
    subscriptions = @stripe.instance_variable_get(:@subscriptions)
    { "sub_elsewhere_id" => { "birth_order_id" => order.id.to_s },
      "sub_elsewhere_ref" => { "birth_order" => SecureRandom.uuid } }.each do |id, metadata|
      subscriptions[id] = { id: id, object: "subscription", status: "active", customer: "cus_other",
        cancel_at_period_end: false, metadata: metadata,
        items: { object: "list", data: [ { price: { id: CONVERSATION_PRICE }, current_period_end: 1.month.from_now.to_i } ] } }
    end

    assert_no_difference "Agent.count" do
      paid_birth.complete!(order)
      assert_raises(Billing::InvalidSubscription) do
        Billing::SubscriptionSync.new("sub_elsewhere_ref", client: @stripe).call
      end
    end
    assert order.reload.pending?
    assert_nil order.stripe_subscription_id
  end

  test "Stripe names the resident only after it is committed, and a failed naming is retried" do
    order, = start!
    @stripe.set_subscription_status("sub_new_1", "active")
    @stripe.fail_next_subscription_update

    assert_raises(Stripe::APIConnectionError) { paid_birth.complete!(order) }
    order.reload
    assert order.born?, "the birth committed before Stripe was told"
    assert Agent.exists?(order.agent_id)
    assert_nil @stripe.subscription("sub_new_1")[:metadata]["agent_id"]
    assert_not ResidentEntitlement.paid_for?(order.agent)

    Billing::SubscriptionSync.new("sub_new_1", client: @stripe).call
    assert_equal order.agent_id.to_s, @stripe.subscription("sub_new_1")[:metadata]["agent_id"]
    assert ResidentEntitlement.paid_for?(order.agent)
  end

  test "a birth rolled back after payment is never named at Stripe" do
    order, = start!
    @stripe.set_subscription_status("sub_new_1", "active")
    Setting.instance.update!(new_residents_on_vm: true, vm_resident_limit: 0)

    assert_raises(Agents::HostedProvisioning::ConfigurationError) { paid_birth.complete!(order) }
    assert_nil @stripe.subscription("sub_new_1")[:metadata]["agent_id"]
    assert_empty @stripe.subscription_updates
  end

  test "once paid, asking for another resident finishes the paid one and charges nothing more" do
    first, = start!
    @stripe.set_subscription_status("sub_new_1", "active")

    error = assert_raises(Billing::PaidBirth::Refused) { start!(name: "Bea") }
    assert_match(/already gone through/, error.message)
    assert_equal 1, @stripe.created_subscriptions.size
    assert first.reload.born?
    assert_equal 0, ResidentBirthOrder.where(state: "pending").count
  end

  test "paying again on an order already paid completes it instead" do
    order, = start!
    @stripe.set_subscription_status("sub_new_1", "active")

    assert_difference "Agent.count", 1 do
      assert_equal({ paid: true }, paid_birth.payment(order))
    end
    assert order.reload.born?
  end

  test "a born order whose answer or link was lost is resumed into linking, not refused" do
    order, = start!
    @stripe.set_subscription_status("sub_new_1", "active")
    @stripe.fail_next_subscription_update
    assert_raises(Stripe::APIConnectionError) { paid_birth.complete!(order) }
    assert order.reload.born?

    assert_no_difference "Agent.count" do
      assert_equal({ paid: true }, paid_birth.payment(order))
    end
    assert_equal order.agent_id.to_s, @stripe.subscription("sub_new_1")[:metadata]["agent_id"]
    assert ResidentEntitlement.paid_for?(order.agent)
  end

  test "an uncertain order is resolved by replaying its call, never by trusting a search miss" do
    @stripe.fail_next_subscription_create(created: true)
    assert_raises(Billing::PaidBirth::Uncertain) { start! }
    earlier = ResidentBirthOrder.sole
    @stripe.search_lags!

    later, = start!(name: "Bea")

    earlier.reload
    assert_equal "sub_new_1", earlier.stripe_subscription_id, "the replay found what Stripe made"
    assert earlier.abandoned?
    assert_includes @stripe.cancelled_subscriptions, "sub_new_1", "the earlier subscription is cancelled, not left open"
    assert later.pending?
    assert_equal "sub_new_2", later.stripe_subscription_id
  end

  test "an uncertain order that was in fact paid is completed, not replaced" do
    @stripe.fail_next_subscription_create(created: true)
    assert_raises(Billing::PaidBirth::Uncertain) { start! }
    @stripe.set_subscription_status("sub_new_1", "active")
    @stripe.search_lags!

    assert_raises(Billing::PaidBirth::Refused) { start!(name: "Bea") }
    assert ResidentBirthOrder.find_by!(stripe_subscription_id: "sub_new_1").born?
    assert_equal 1, @stripe.created_subscriptions.size
  end

  test "the replay uses the card the order was opened with, so its parameters match" do
    @stripe.fail_next_subscription_create(created: true)
    assert_raises(Billing::PaidBirth::Uncertain) { start! }
    order = ResidentBirthOrder.sole
    assert_equal "pm_visa", order.stripe_payment_method_id
    @stripe.put_payment_method("pm_mastercard", brand: "mastercard", last4: "4444")
    @stripe.put_customer("cus_1", default_payment_method: "pm_mastercard")

    result = paid_birth.payment(order)
    assert_equal "pm_mastercard", result[:payment_method_id], "paying then uses the card now on the account"
    assert_equal 1, @stripe.created_subscriptions.size
    assert_equal "pm_visa", @stripe.created_subscriptions.sole.first[:default_payment_method]
  end

  # #619: a re-costing between the first attempt and its replay must not
  # change the replayed parameters, which share an idempotency key.
  test "the replay uses the price the order was opened with, even after the plan is re-costed" do
    @stripe.fail_next_subscription_create(created: true)
    assert_raises(Billing::PaidBirth::Uncertain) { start! }
    order = ResidentBirthOrder.sole
    assert_equal CONVERSATION_PRICE, order.stripe_price_id
    assert_equal "standard", order.rate

    ENV["STRIPE_PRICE_CONVERSATION"] = "price_test_conversation_v2,#{CONVERSATION_PRICE}"
    assert_equal "price_test_conversation_v2", @tier.price_id
    paid_birth.payment(order)

    assert_equal 1, @stripe.created_subscriptions.size
    assert_equal [ { price: CONVERSATION_PRICE } ], @stripe.created_subscriptions.sole.first[:items]
  end

  test "an at-cost order opens the at-cost price and says so to Stripe" do
    grant = BillingCode.redeem!(code: BillingCode.create!(code: "PEPE", effect: "at_cost", created_by: users(:site_admin_user)).code,
      account: @account, by: @owner)
    order, = paid_birth.start!(account: @account, creator: @owner, open_beginning: false, tier: @tier, rate: "at_cost",
      attributes: { name: "Aria", system_prompt: "Be curious.", model_id: "openrouter/auto" })
    assert_equal "at_cost", order.rate
    assert_equal CONVERSATION_AT_COST_PRICE, order.stripe_price_id
    assert_equal grant, order.billing_code_redemption
    params, = @stripe.created_subscriptions.sole
    assert_equal [ { price: CONVERSATION_AT_COST_PRICE } ], params[:items]
    assert_equal "at_cost", params[:metadata][:rate]
    assert_equal grant.id.to_s, params[:metadata][:redemption_id]
    assert_equal "Conversation at cost hosting for Aria", params[:description]
  end

  # Cross-deploy replay: an uncertain order opened by the deploy before rates
  # existed is replayed by this one under the same idempotency key, so a
  # standard order's payload must be exactly what that deploy sent.
  test "a standard order's payload is exactly the pre-rates shape, and a replay sends it again unchanged" do
    @stripe.fail_next_subscription_create(created: true)
    assert_raises(Billing::PaidBirth::Uncertain) { start! }
    order = ResidentBirthOrder.sole
    first, = @stripe.created_subscriptions.sole
    assert_equal({
      customer: "cus_1",
      items: [ { price: CONVERSATION_PRICE } ],
      default_payment_method: "pm_visa",
      payment_behavior: "default_incomplete",
      payment_settings: { save_default_payment_method: "on_subscription" },
      automatic_tax: { enabled: true },
      description: "Conversation hosting for Aria",
      metadata: { birth_order: order.reference, account_id: @account.id.to_s, tier: "conversation" },
      expand: [ "latest_invoice.confirmation_secret" ]
    }, first)

    # The fake refuses a replay whose payload differs from the first call.
    paid_birth.payment(order)
    assert_equal 1, @stripe.created_subscriptions.size
  end

  test "an at-cost order needs a grant the account holds" do
    error = assert_raises(Billing::PaidBirth::Refused) do
      paid_birth.start!(account: @account, creator: @owner, open_beginning: false, tier: @tier, rate: "at_cost",
        attributes: { name: "Aria", system_prompt: "Be curious.", model_id: "openrouter/auto" })
    end
    assert_match(/can't buy plans at that rate/, error.message)
    assert_equal 0, @stripe.created_subscriptions.size
    assert_equal 0, ResidentBirthOrder.count
  end

  test "an at-cost order on a house-funded model is refused before any money moves" do
    BillingCode.redeem!(code: BillingCode.create!(code: "PEPE", effect: "at_cost", created_by: users(:site_admin_user)).code,
      account: @account, by: @owner)
    error = assert_raises(Billing::PaidBirth::Refused) do
      paid_birth.start!(account: @account, creator: @owner, open_beginning: false, tier: @tier, rate: "at_cost",
        attributes: { name: "Aria", system_prompt: "Be curious.", model_id: HouseInference::Offering::DEFAULT_MODEL_ID })
    end
    assert_match(/includes no house model/, error.message)
    assert_equal 0, @stripe.created_subscriptions.size
    assert_equal 0, ResidentBirthOrder.count
  end

  test "births that don't pay are refused in an account that pays" do
    error = assert_raises(Billing::BirthGate::Refused) do
      Agents::HostedBirth.new(account: @account, creator: @owner,
        attributes: { name: "Free", system_prompt: "x", model_id: "openrouter/auto" }).create!
    end
    assert_equal Billing::BirthGate::NEEDS_PLAN, error.message
  end

end
