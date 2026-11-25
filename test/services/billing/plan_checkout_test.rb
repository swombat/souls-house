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
    assert_equal [ "card" ], params[:allowed_payment_method_types], "a card pays before Checkout completes; no delayed methods"
    assert_nil params[:payment_method_types], "Stripe refuses payment_method_types on a Checkout Session since 2026-09-30.endive"
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

  test "a create Stripe refuses outright frees the first bill, and the next try is a new attempt" do
    @stripe.fail_next_checkout_create(
      Stripe::InvalidRequestError.new("No such price: 'price_gone'", "line_items[0][price]", http_status: 400), created: false)
    error = assert_raises(Billing::NotReady) { checkout.url }
    assert_match(/refused this Checkout, and nothing was charged/, error.message)
    assert attempts.sole.resolved_at, "no session was made, so nothing holds the first bill"
    assert_not Billing::FirstBill.waiting?(@account)

    # The cause corrected, the owner tries again.
    assert_equal "https://checkout.stripe.com/c/pay/cs_test_1", checkout.url
    assert_equal 2, attempts.count
    assert_equal "cs_test_1", attempts.unresolved.sole.stripe_session_id
  end

  test "a create with no certain answer is never taken as refused" do
    [ Stripe::IdempotencyError.new("Keys for idempotent requests can only be used with the same parameters"),
      Stripe::APIError.new("Stripe had a problem", http_status: 500),
      Stripe::RateLimitError.new("Too many requests", http_status: 429),
      Stripe::InvalidRequestError.new("No status", "id") ].each do |fault|
      @stripe.fail_next_checkout_create(fault, created: false)
      assert_raises(Billing::NotReady, Stripe::StripeError) { checkout.url }
      assert_nil attempts.sole.resolved_at, "#{fault.class} (#{fault.http_status.inspect}) keeps the attempt pinned"
      assert Billing::FirstBill.waiting?(@account)
    end
  end

  test "a 400 on a replay after a send with no answer keeps the attempt: that send may have made a session" do
    @stripe.fail_next_checkout_create # Stripe made the session; the answer was lost.
    assert_raises(Billing::NotReady, Stripe::APIConnectionError) { checkout.url }

    @stripe.fail_next_checkout_send(
      Stripe::InvalidRequestError.new("Invalid request", "line_items", http_status: 400))
    assert_raises(Stripe::InvalidRequestError) { checkout.url }
    assert_nil attempts.sole.resolved_at, "a replay's 400 proves nothing about the first send"
    assert Billing::FirstBill.waiting?(@account)

    # The next replay finds the session the first send made.
    assert_equal "https://checkout.stripe.com/c/pay/cs_test_1", checkout.url
    assert_equal "cs_test_1", attempts.sole.stripe_session_id
    assert_equal 1, @stripe.checkout_sessions.size
  end

  test "a 400 on a replay is never taken as refused, even when the first send made nothing" do
    @stripe.fail_next_checkout_create(Stripe::APIConnectionError.new("timed out"), created: false)
    assert_raises(Billing::NotReady, Stripe::APIConnectionError) { checkout.url }
    @stripe.fail_next_checkout_send(Stripe::InvalidRequestError.new("Invalid request", "line_items", http_status: 400))
    assert_raises(Stripe::InvalidRequestError) { checkout.url }
    assert_nil attempts.sole.resolved_at
  end

  test "completed with the payment still to come: the first bill stays held until it is paid" do
    checkout.url
    @stripe.complete_checkout_session("cs_test_1", subscription_id: "sub_slow", payment_status: "unpaid")
    sync("sub_slow")
    Billing::Checkout.release_expired!(@account, client: @stripe)
    assert_nil attempts.sole.resolved_at, "an unpaid session may still be paid"
    assert Billing::FirstBill.waiting?(@account)
    assert_raises(Billing::AlreadySubscribed) { checkout("colleagues").url }
    assert_equal 1, @stripe.checkout_sessions.size

    @stripe.set_subscription_status("sub_slow", "active")
    sync("sub_slow")
    assert attempts.sole.resolved_at
    assert_equal "partners", @account.reload.plan.id
  end

  test "completed with the payment still to come: the hold is released once Stripe ends it unpaid" do
    checkout.url
    @stripe.complete_checkout_session("cs_test_1", subscription_id: "sub_slow", payment_status: "unpaid")
    @stripe.set_subscription_status("sub_slow", "past_due")
    Billing::Checkout.release_expired!(@account, client: @stripe)
    assert_nil attempts.sole.resolved_at, "only incomplete_expired ends it"

    @stripe.set_subscription_status("sub_slow", "incomplete_expired")
    sync("sub_slow")
    assert_empty AccountSubscription.where(account: @account)
    Billing::Checkout.release_expired!(@account, client: @stripe)
    assert attempts.sole.resolved_at
    assert_not Billing::FirstBill.waiting?(@account)
    assert_equal "https://checkout.stripe.com/c/pay/cs_test_2", checkout.url
  end

  test "a new Checkout replaces one Stripe ended unpaid, under its own lock" do
    checkout.url
    @stripe.complete_checkout_session("cs_test_1", subscription_id: "sub_slow", payment_status: "unpaid")
    @stripe.set_subscription_status("sub_slow", "incomplete_expired")
    # Release the sweep can't see (it runs first in url); settle! decides.
    Billing::CheckoutSession.stub(:release_expired!, nil) do
      assert_equal "https://checkout.stripe.com/c/pay/cs_test_2", checkout("colleagues").url
    end
    assert_equal [ "colleagues" ], attempts.unresolved.pluck(:plan)
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
