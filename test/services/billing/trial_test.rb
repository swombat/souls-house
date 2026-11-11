require "test_helper"
require "support/fake_stripe"

# The free trial (Billing::Trial): a small resident for 14 days through Stripe
# Checkout, no card, once per account ever.
class Billing::TrialTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  SUCCESS = "https://souls.test/return".freeze
  CANCEL = "https://souls.test/new".freeze

  setup do
    Setting.instance.update!(allow_agents: true)
    @account = accounts(:personal_account)
    @account.update!(billing_required: true)
    @owner = users(:user_1)
    @stripe = FakeStripe.new
  end

  def paid_birth = Billing::PaidBirth.new(client: @stripe)

  def start_trial!(creator: @owner, **overrides)
    paid_birth.start_trial!(account: @account, creator: creator, open_beginning: false,
      attributes: { name: "Aria", system_prompt: "Be curious.", model_id: "openrouter/auto" }.merge(overrides),
      success_url: ->(order) { "#{SUCCESS}/#{order.to_param}" }, cancel_url: CANCEL)
  end

  test "the trial opens a card-optional Checkout for a small resident, without a card, creating nothing yet" do
    order = nil
    assert_no_difference [ "Agent.count", "ResidentSubscription.count" ] do
      order, url = start_trial!
      assert_equal "https://checkout.stripe.com/c/pay/cs_test_1", url
    end

    assert order.trial?
    assert order.pending?
    assert_equal "conversation", order.tier
    assert_equal "standard", order.rate
    assert_equal "cs_test_1", order.stripe_checkout_session_id
    assert_not_nil @account.reload.trial_started_at
    assert_empty @stripe.created_subscriptions, "a trial never opens a subscription itself"

    params, opts = @stripe.checkout_sessions.sole
    assert_equal "souls-house-birth-trial-#{order.reference}", opts[:idempotency_key]
    assert_equal "subscription", params[:mode]
    assert_equal "if_required", params[:payment_method_collection]
    assert_equal 14, params.dig(:subscription_data, :trial_period_days)
    assert_equal({ end_behavior: { missing_payment_method: "cancel" } }, params.dig(:subscription_data, :trial_settings))
    assert_equal [ { price: CONVERSATION_PRICE, quantity: 1 } ], params[:line_items]
    metadata = { birth_order: order.reference, account_id: @account.id.to_s, tier: "conversation", trial: "1" }
    assert_equal metadata, params[:metadata]
    assert_equal metadata, params.dig(:subscription_data, :metadata)
    assert_equal "Small hosting for Aria", params.dig(:subscription_data, :description)
    assert_equal({ enabled: true }, params[:automatic_tax])
    assert_equal "required", params[:billing_address_collection]
    assert_equal "#{SUCCESS}/#{order.to_param}", params[:success_url]
    assert_equal order.expires_at.to_i, params[:expires_at]
    assert_equal 1, @stripe.created_customers.size, "the customer is made for an account that has none"
  end

  test "a paid order's subscription payload and idempotency key are unchanged by the trial" do
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    @stripe.put_payment_method("pm_visa")
    @stripe.put_customer("cus_1", default_payment_method: "pm_visa")

    order, = paid_birth.start!(account: @account, creator: @owner, open_beginning: false, tier: Billing::Tier.find!("conversation"),
      attributes: { name: "Aria", system_prompt: "Be curious.", model_id: "openrouter/auto" })

    params, opts = @stripe.created_subscriptions.sole
    assert_equal "souls-house-birth-order-#{order.reference}", opts[:idempotency_key]
    assert_equal %i[automatic_tax customer default_payment_method description expand items metadata payment_behavior
      payment_settings].sort, params.keys.sort
    assert_equal({ birth_order: order.reference, account_id: @account.id.to_s, tier: "conversation" }, params[:metadata])
    assert_not order.trial?
    assert_nil @account.reload.trial_started_at, "a paid birth claims no trial"
    assert_empty @stripe.checkout_sessions
  end

  test "an uncertain Checkout create keeps the order and replays the identical payload under the same key" do
    @stripe.fail_next_checkout_create(created: true)
    error = assert_raises(Billing::PaidBirth::Uncertain) { start_trial! }
    order = error.order
    assert order.pending?
    assert_nil order.stripe_checkout_session_id

    result = paid_birth.payment(order)
    assert_equal "https://checkout.stripe.com/c/pay/cs_test_1", result[:checkout_url]
    assert_equal "cs_test_1", order.reload.stripe_checkout_session_id
    assert_equal 1, @stripe.checkout_sessions.size, "the replay returned the session Stripe made the first time"
  end

  test "completing the Checkout bears the resident on a trialing subscription that carries the allowance" do
    order, = start_trial!
    @stripe.complete_checkout_session("cs_test_1", subscription_id: "sub_trial", trial_end: Time.utc(2026, 11, 24, 12))

    assert_difference "Agent.count", 1 do
      assert_equal({ paid: true }, paid_birth.payment(order))
    end
    order.reload
    assert order.born?
    assert_equal "sub_trial", order.stripe_subscription_id
    subscription = ResidentSubscription.find_by!(stripe_subscription_id: "sub_trial")
    assert_equal "trialing", subscription.stripe_status
    assert_equal Time.utc(2026, 11, 24, 12), subscription.trial_end
    assert_equal Time.utc(2026, 11, 24, 12), subscription.trial_ends_at
    entitlement = ResidentEntitlement.find_by!(agent: order.agent)
    assert entitlement.active?
    assert_equal BigDecimal("10"), entitlement.allowance_limit, "the trial's $10"
    assert_equal order.agent_id.to_s, @stripe.subscription("sub_trial")[:metadata]["agent_id"]
  end

  test "once per account: a born trial is never offered again, to anyone" do
    order, = start_trial!
    @stripe.complete_checkout_session("cs_test_1", subscription_id: "sub_trial")
    paid_birth.complete!(order)
    assert_not Billing::Trial.eligible?(@account.reload)

    error = assert_raises(Billing::PaidBirth::Refused) { start_trial!(name: "Bea") }
    assert_match "already had its free trial", error.message
    assert_equal 1, @stripe.checkout_sessions.size
  end

  test "a claim another tab or request already holds is refused under the claim, and the backstop index holds" do
    @account.update_column(:trial_started_at, 1.minute.ago) # the other tab's claim, committed first
    assert_raises(Billing::PaidBirth::Refused) do
      Billing::Trial.claim!(@account) { flunk "must not yield" }
    end

    @account.update_column(:trial_started_at, nil)
    ResidentBirthOrder.create!(account: @account, creator: @owner, tier: "conversation", rate: "standard", trial: true,
      birth_attributes: { name: "A" })
    assert_raises(ActiveRecord::RecordNotUnique) do
      ResidentBirthOrder.create!(account: @account, creator: @owner, tier: "conversation", rate: "standard", trial: true,
        birth_attributes: { name: "B" })
    end
  end

  test "the same person starting again replaces their waiting trial, expiring its Checkout, and still holds one claim" do
    first, = start_trial!
    second, url = start_trial!(name: "Bea")

    assert first.reload.abandoned?
    assert_equal [ "cs_test_1" ], @stripe.expired_sessions
    assert second.pending?
    assert_equal "https://checkout.stripe.com/c/pay/cs_test_2", url
    assert_not_nil @account.reload.trial_started_at
    assert_equal 1, ResidentBirthOrder.where(account: @account, trial: true, state: %w[pending born failed]).count
  end

  test "an earlier trial whose Checkout completed meanwhile is born, not replaced" do
    first, = start_trial!
    @stripe.complete_checkout_session("cs_test_1", subscription_id: "sub_trial")

    error = assert_raises(Billing::PaidBirth::Refused) { start_trial!(name: "Bea") }
    assert_match "already gone through", error.message
    assert first.reload.born?
    assert_equal 1, @stripe.checkout_sessions.size
  end

  test "an abandoned trial whose Checkout expired gives the claim back" do
    order, = start_trial!
    travel_to order.expires_at + 1.minute do
      paid_birth.abandon_expired!(order)
    end

    assert order.reload.abandoned?
    assert_equal [ "cs_test_1" ], @stripe.expired_sessions
    assert_nil @account.reload.trial_started_at
    assert Billing::Trial.eligible?(@account)
  end

  test "the sweeper bears a trial whose Checkout completed at the last moment" do
    order, = start_trial!
    @stripe.complete_checkout_session("cs_test_1", subscription_id: "sub_trial")
    travel_to order.expires_at + 1.minute do
      paid_birth.abandon_expired!(order)
    end

    assert order.reload.born?
    assert_not_nil @account.reload.trial_started_at
  end

  test "who is offered it: an account that pays, has never had a subscription, while Site Admin offers it" do
    assert Billing::Trial.eligible?(@account)
    assert_equal({ eligible: true, days: 14 }, Billing::Trial.as_json_for(@account))

    Setting.instance.update!(free_trial_enabled: false)
    assert_not Billing::Trial.eligible?(@account)
    assert_raises(Billing::PaidBirth::Refused) { start_trial! }
    Setting.instance.update!(free_trial_enabled: true)

    @account.update!(billing_required: false)
    assert_not Billing::Trial.eligible?(@account)
    @account.update!(billing_required: true)

    agent = agents(:research_assistant)
    ResidentSubscription.create!(agent: agent, account: @account, stripe_subscription_id: "sub_old", tier: "conversation",
      stripe_status: "canceled")
    assert_not Billing::Trial.eligible?(@account), "an account that ever had a subscription had its chance to pay"
    assert_raises(Billing::PaidBirth::Refused) { start_trial! }
    assert_empty @stripe.checkout_sessions
  end

  test "Site Admin offers the trial by default" do
    assert Setting.instance.free_trial_enabled?
  end

end
