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
    assert_equal order.id.to_s, params[:metadata][:birth_order_id]
    assert_nil params[:metadata][:agent_id]
    assert_equal "souls-house-birth-order-#{order.id}", opts[:idempotency_key]
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

    client_secret, payment_method = paid_birth.payment(order)

    assert_equal "pi_sub_new_1_secret", client_secret
    assert_equal "pm_mastercard", payment_method
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

  test "births that don't pay are refused in an account that pays" do
    error = assert_raises(Billing::BirthGate::Refused) do
      Agents::HostedBirth.new(account: @account, creator: @owner,
        attributes: { name: "Free", system_prompt: "x", model_id: "openrouter/auto" }).create!
    end
    assert_equal Billing::BirthGate::NEEDS_PLAN, error.message
  end

end
