require "test_helper"
require "support/fake_stripe"

# A plan bought by itself as the account's first bill (Billing::PlanCheckout,
# jGgWgj): Stripe Checkout, one line, the attempt committed first, and the
# first bill held while it could still be paid.
class Billing::PlanCheckoutTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  SUCCESS = "https://souls.test/billing?checkout=success".freeze
  CANCEL = "https://souls.test/billing".freeze

  setup do
    Setting.instance.update!(allow_agents: true)
    @account = accounts(:personal_account)
    @account.update!(billing_required: true)
    @owner = users(:user_1)
    @stripe = FakeStripe.new
  end

  def checkout(plan = "partners") = Billing::PlanCheckout.new(account: @account, plan: Billing::AccountPlan.find!(plan),
    success_url: SUCCESS, cancel_url: CANCEL, client: @stripe)

  def paid_birth = Billing::PaidBirth.new(client: @stripe)
  def attempts = AccountPlanCheckoutAttempt.where(account: @account)
  def sync(id) = Billing::BillSync.new(id, client: @stripe).call

  test "opens a one-line subscription Checkout for the plan, its intent committed first, and grants nothing" do
    url = checkout.url
    assert_equal "https://checkout.stripe.com/c/pay/cs_test_1", url

    attempt = attempts.sole
    params, opts = @stripe.checkout_sessions.sole
    assert_equal attempt.idempotency_key, opts[:idempotency_key]
    assert_equal json(params), attempt.create_params
    assert_equal [ "partners", PARTNERS_PRICE, "cs_test_1" ], [ attempt.plan, attempt.stripe_price_id, attempt.stripe_session_id ]
    assert_equal "subscription", params[:mode]
    assert_equal [ { price: PARTNERS_PRICE, quantity: 1 } ], params[:line_items]
    metadata = { kind: "account_plan", plan: "partners", account_id: @account.id.to_s,
                 plan_checkout_attempt: attempt.idempotency_key }
    assert_equal metadata, params[:metadata]
    assert_equal metadata, params.dig(:subscription_data, :metadata)
    assert_equal({ enabled: true }, params[:automatic_tax])
    assert_equal "companions", @account.reload.plan.id, "nothing is given before Stripe confirms the payment"
    assert_not Billing::Reconcile.applies?(@account)
  end

  test "the same plan again gives the same open Checkout; another plan closes it first" do
    first = checkout.url
    assert_equal first, checkout.url
    assert_equal 1, @stripe.checkout_sessions.size

    checkout("colleagues").url
    assert_equal [ "cs_test_1" ], @stripe.expired_sessions
    assert_equal [ "colleagues" ], attempts.unresolved.pluck(:plan)
  end

  test "paid: the subscription comes in as the plan alone, and the attempt is resolved with it" do
    checkout.url
    @stripe.complete_checkout_session("cs_test_1", subscription_id: "sub_plan")
    sync("sub_plan")

    assert_equal "partners", @account.reload.plan.id
    assert_equal({ PARTNERS_PRICE => 1 }, Billing::BillSync.house_lines("sub_plan"))
    assert_empty ResidentSubscription.where(account: @account)
    assert attempts.sole.resolved_at
    assert Billing::Reconcile.applies?(@account)
    assert_not Billing::Trial.eligible?(@account), "a plan paid for is past the trial"

    error = assert_raises(Billing::AlreadySubscribed) { checkout("colleagues").url }
    assert_match(/already pays a bill/, error.message)
  end

  test "a create with no answer holds the first bill: a trial is refused, never a second bill, and the late payment settles it" do
    @stripe.fail_next_checkout_create
    assert_raises(Billing::NotReady, Stripe::APIConnectionError) { checkout.url }
    attempt = attempts.sole
    assert_nil attempt.stripe_session_id

    error = assert_raises(Billing::PaidBirth::Refused) do
      paid_birth.start_trial!(account: @account, creator: @owner, open_beginning: false,
        attributes: { name: "Aria", system_prompt: "Be curious.", model_id: "openrouter/auto" },
        success_url: SUCCESS, cancel_url: CANCEL)
    end
    assert_equal Billing::FirstBill::WAITING, error.message
    assert_equal 1, @stripe.checkout_sessions.size, "no second Checkout"
    assert_empty @stripe.created_subscriptions

    # Stripe made the session; the owner paid it before anyone here knew.
    session_id = @stripe.session_states.keys.sole
    @stripe.complete_checkout_session(session_id, subscription_id: "sub_late")
    sync("sub_late")
    assert attempt.reload.resolved_at, "the original attempt is settled by the late payment"
    assert_equal "partners", @account.reload.plan.id
  end

  test "an expired plan Checkout stops holding the first bill" do
    checkout.url
    @stripe.session_states["cs_test_1"][:status] = "expired"
    Billing::Checkout.release_expired!(@account, client: @stripe)
    assert attempts.sole.resolved_at
    assert_not Billing::FirstBill.waiting?(@account)
  end

  test "refused when the house already gives that plan or more" do
    @account.update!(granted_plan: "colleagues")
    error = assert_raises(Billing::NotEligible) { checkout("partners").url }
    assert_match(/already has the Colleagues plan/, error.message)
    assert_empty attempts
  end

  test "after a plan-only Checkout the first resident joins that bill as the included one, with no card asked for" do
    checkout.url
    @stripe.complete_checkout_session("cs_test_1", subscription_id: "sub_plan")
    # Stripe Checkout saves the card on the subscription, not the customer.
    @stripe.put_payment_method("pm_checkout")
    @stripe.subscription("sub_plan")[:default_payment_method] = "pm_checkout"
    sync("sub_plan")
    assert_equal "4242", Billing::PaymentMethod.new(account: @account, client: @stripe).current&.last4

    order, secret, = paid_birth.start!(account: @account, creator: @owner, open_beginning: true,
      tier: Billing::Tier.find!("conversation"),
      attributes: { name: "Aria", system_prompt: "", model_id: "openrouter/auto" })
    assert order.item?
    assert_nil secret
    assert_equal "included", order.rate
  end

  private

  def json(value) = JSON.parse(JSON.generate(value))

end
