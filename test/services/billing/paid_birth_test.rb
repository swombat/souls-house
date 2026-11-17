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

  # An order as a deploy before 17 Nov opened it: one standard line, no plan.
  def legacy_order!(description: "Small hosting for Aria")
    ResidentBirthOrder.create!(account: @account, creator: @owner, tier: "conversation", rate: "standard",
      stripe_price_id: CONVERSATION_PRICE, stripe_description: description, stripe_payment_method_id: "pm_visa",
      birth_attributes: { name: "Aria", system_prompt: "Be curious.", model_id: "openrouter/auto" }, open_beginning: false)
  end

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
    # The plan includes its resident: the first bill is the plan and that
    # resident at the included price (Daniel, jaMWBj jRyMoO 2026-11-13).
    assert_equal [ { price: COMPANIONS_PRICE }, { price: CONVERSATION_INCLUDED_PRICE } ], params[:items]
    assert_equal [ "companions", COMPANIONS_PRICE ], [ order.plan, order.plan_stripe_price_id ]
    assert_equal [ "included", CONVERSATION_INCLUDED_PRICE ], [ order.rate, order.stripe_price_id ]
    assert_equal "companions", params[:metadata][:plan]
    assert_equal "included", params[:metadata][:rate]
    assert_equal "Companions plan, including Aria (Small)", params[:description]
    assert_equal "pm_visa", params[:default_payment_method]
    assert_equal "default_incomplete", params[:payment_behavior]
    assert_equal({ enabled: true }, params[:automatic_tax])
    assert_equal order.reference, params[:metadata][:birth_order]
    assert_nil params[:metadata][:agent_id]
    assert_equal "souls-house-birth-order-#{order.reference}", opts[:idempotency_key]
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, order.reference)
  end

  test "the first bill carries the plan the account chose, its resident included at the size less a Small" do
    @account.update!(chosen_plan: "partners")
    @tier = Billing::Tier.find!("life")
    order, = start!
    params, = @stripe.created_subscriptions.sole
    assert_equal [ { price: PARTNERS_PRICE }, { price: LIFE_INCLUDED_PRICE } ], params[:items]
    assert_equal BigDecimal("30"), order.offer.monthly_usd, "a Medium as the included resident costs the difference"
    assert_equal "Partners plan, including Aria (Medium)", params[:description]
  end

  test "a given plan is a free account: no plan line, and its Small is free" do
    # Daniel, jaMWBj YkMbQn 2026-11-13: "a discount code that gives people a
    # free account ... for each account size".
    @account.update!(granted_plan: "partners", chosen_plan: "partners")
    order, secret, = start!
    params, = @stripe.created_subscriptions.sole
    assert_equal [ { price: CONVERSATION_INCLUDED_PRICE } ], params[:items]
    assert_nil order.plan
    assert_nil params[:metadata][:plan]
    assert_equal "included", order.rate
    # A $0 first bill is settled by Stripe at once: nothing to pay, and the
    # resident is born on it.
    assert_nil secret
    paid_birth.complete!(order)
    assert order.reload.born?
    assert_equal "included", ResidentSubscription.find_by!(agent: order.agent).rate
    assert_empty AccountSubscription.where(account: @account), "a free account has no plan line"
  end

  test "control: a grant lower than the plan chosen still pays for the plan chosen" do
    @account.update!(granted_plan: "companions", chosen_plan: "colleagues")
    order, secret, = start!
    assert_equal "colleagues", order.plan
    assert_equal [ { price: COLLEAGUES_PRICE }, { price: CONVERSATION_INCLUDED_PRICE } ],
      @stripe.created_subscriptions.sole.first[:items]
    assert secret, "a bill with money on it is paid by card"
  end

  test "an at-cost code gives no free residence: a Small bought at the catalogue price is standard, with no plan line" do
    # Daniel, jaMWBj YkMbQn 2026-11-13: "an at-cost residence, no free residence".
    BillingCode.redeem!(code: BillingCode.create!(code: "ATCOST", effect: "at_cost", created_by: users(:site_admin_user)).code,
      account: @account, by: @owner)
    order, = start!
    params, = @stripe.created_subscriptions.sole
    assert_equal [ { price: CONVERSATION_PRICE } ], params[:items]
    assert_equal "standard", order.rate
    assert_nil order.plan
  end

  test "the buyer can't ask for the included rate; the house decides it" do
    error = assert_raises(Billing::PaidBirth::Refused) do
      paid_birth.start!(account: @account, creator: @owner, open_beginning: false, tier: @tier, rate: "included",
        attributes: { name: "Aria", system_prompt: "Be curious.", model_id: "openrouter/auto" })
    end
    assert_match(/set by the house/, error.message)
    assert_equal 0, @stripe.created_subscriptions.size
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
    assert_empty @stripe.subscription_updates, "the house's row says whose it is; Stripe is not written to again"
    entitlement = ResidentEntitlement.find_by!(agent: agent)
    assert entitlement.active?
    assert_equal "conversation", entitlement.tier
    assert ResidentEntitlement.paid_for?(agent)
  end

  test "the browser and the webhook can both complete it; the resident is born once" do
    order, = start!
    @stripe.set_subscription_status("sub_new_1", "active")

    assert_difference "Agent.count", 1 do
      Billing::BillSync.new("sub_new_1", client: @stripe).call
      paid_birth.complete!(order)
      Billing::BillSync.new("sub_new_1", client: @stripe).call
    end
    assert order.reload.born?
    assert_equal 1, ResidentSubscription.where(stripe_subscription_id: "sub_new_1").count
  end

  test "a webhook for an unpaid order changes nothing" do
    start!
    assert_nil Billing::BillSync.new("sub_new_1", client: @stripe).call
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

    assert_no_difference "Agent.count" do
      assert_raises(Agents::HostedProvisioning::ConfigurationError) { paid_birth.complete!(order) }
    end
    assert_equal "Aria", order.reload.resident_name

    Setting.instance.update!(new_residents_on_vm: false)
    assert_difference "Agent.count", 1 do
      paid_birth.complete!(order)
    end
    assert order.reload.born?
    assert_equal({}, order.birth_attributes)
    assert_nil order.last_error
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
      Billing::BillSync.new("sub_new_1", client: @stripe).call
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
        Billing::BillSync.new("sub_elsewhere_ref", client: @stripe).call
      end
    end
    assert order.reload.pending?
    assert_nil order.stripe_subscription_id
  end

  test "the plan comes into force only after the birth is committed, and a lost sync is finished by the next one" do
    order, = start!
    @stripe.set_subscription_status("sub_new_1", "active")

    lost = ->(*, **) { raise Stripe::APIConnectionError.new("timed out") }
    Billing::BillSync.stub(:new, lost) do
      assert_raises(Stripe::APIConnectionError) { paid_birth.complete!(order) }
    end
    order.reload
    assert order.born?, "the birth committed before the subscription was brought in"
    assert Agent.exists?(order.agent_id)
    assert_not ResidentEntitlement.paid_for?(order.agent)

    Billing::BillSync.new("sub_new_1", client: @stripe).call
    assert ResidentEntitlement.paid_for?(order.agent)
    assert_equal [ order.agent_id ], ResidentSubscription.where(stripe_subscription_id: "sub_new_1").pluck(:agent_id)
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
    lost = ->(*, **) { raise Stripe::APIConnectionError.new("timed out") }
    Billing::BillSync.stub(:new, lost) do
      assert_raises(Stripe::APIConnectionError) { paid_birth.complete!(order) }
    end
    assert order.reload.born?

    assert_no_difference "Agent.count" do
      assert_equal({ paid: true }, paid_birth.payment(order))
    end
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
    assert_equal CONVERSATION_INCLUDED_PRICE, order.stripe_price_id
    assert_equal "included", order.rate

    ENV["STRIPE_PRICE_CONVERSATION_INCLUDED"] = "price_test_conversation_included_v2,#{CONVERSATION_INCLUDED_PRICE}"
    ENV["STRIPE_PRICE_ACCOUNT_COMPANIONS"] = "price_test_account_companions_v2,#{COMPANIONS_PRICE}"
    assert_equal "price_test_conversation_included_v2", @tier.offer("included").price_id
    paid_birth.payment(order)

    assert_equal 1, @stripe.created_subscriptions.size
    assert_equal [ { price: COMPANIONS_PRICE }, { price: CONVERSATION_INCLUDED_PRICE } ],
      @stripe.created_subscriptions.sole.first[:items]
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
    assert_equal "Small at cost hosting for Aria", params[:description]
  end

  # Cross-deploy replay: an uncertain order opened by the deploy before rates
  # existed is replayed by this one under the same idempotency key, so a
  # standard order's payload must be exactly what that deploy sent.
  test "a standard order's payload is exactly the pre-rates shape, and a replay sends it again unchanged" do
    order = legacy_order!
    @stripe.fail_next_subscription_create(created: true)
    assert_raises(Billing::PaidBirth::Uncertain) { paid_birth.payment(order) }
    first, = @stripe.created_subscriptions.sole
    assert_equal({
      customer: "cus_1",
      items: [ { price: CONVERSATION_PRICE } ],
      default_payment_method: "pm_visa",
      payment_behavior: "default_incomplete",
      payment_settings: { save_default_payment_method: "on_subscription" },
      automatic_tax: { enabled: true },
      description: "Small hosting for Aria",
      metadata: { birth_order: order.reference, account_id: @account.id.to_s, tier: "conversation" },
      expand: [ "latest_invoice.confirmation_secret" ]
    }, first)

    # The fake refuses a replay whose payload differs from the first call.
    paid_birth.payment(order)
    assert_equal 1, @stripe.created_subscriptions.size
  end

  # The sizes were renamed (2026-11-10) while orders may be uncertain: an
  # order opened before then has no pinned description, and its replay must
  # send the old name byte for byte.
  test "an order from before the rename replays with its old description" do
    order = legacy_order!
    @stripe.fail_next_subscription_create(created: true)
    assert_raises(Billing::PaidBirth::Uncertain) { paid_birth.payment(order) }
    first, = @stripe.created_subscriptions.sole
    assert_equal "Small hosting for Aria", first[:description]
    assert_equal "Small hosting for Aria", order.stripe_description

    # As an older deploy would have opened it.
    order.update_columns(stripe_description: nil)
    @stripe.subscription(@stripe.created_subscriptions.size.then { |n| "sub_new_#{n}" })[:create_params][:description] =
      "Conversation hosting for Aria"
    paid_birth.payment(order)
    assert_equal 1, @stripe.created_subscriptions.size, "replayed, not refused or made again"
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

  test "an at-cost order with no model named is judged on the default the birth would use" do
    BillingCode.redeem!(code: BillingCode.create!(code: "PEPE", effect: "at_cost", created_by: users(:site_admin_user)).code,
      account: @account, by: @owner)
    HouseInference::Offering.stub(:configured?, true) do
      assert_equal HouseInference::Offering::DEFAULT_MODEL_ID,
        Agents::HostedBirth.default_model_id(account: @account, creator: @owner), "the default is a house model here"
      error = assert_raises(Billing::PaidBirth::Refused) do
        paid_birth.start!(account: @account, creator: @owner, open_beginning: false, tier: @tier, rate: "at_cost",
          attributes: { name: "Aria", system_prompt: "Be curious." })
      end
      assert_match(/includes no house model/, error.message)
    end
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
