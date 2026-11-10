require "test_helper"
require "support/fake_stripe"

class Billing::AccountPlanCheckoutTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    @account = accounts(:personal_account)
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
  end

  # Lock behaviour itself is CheckoutLock's (CheckoutLockTest).
  def checkout(plan = "partners")
    Billing::CheckoutLock.stub(:synchronize_account, ->(_account, &operation) { operation.call }) do
      Billing::AccountPlanCheckout.new(account: @account, plan: Billing::AccountPlan.find!(plan), client: @stripe,
        success_url: "https://souls.example/ok", cancel_url: "https://souls.example/no").url
    end
  end

  test "one line item for the plan, kind=account_plan metadata, Checkout's tax and address settings" do
    url = checkout("colleagues")

    params, opts = @stripe.checkout_sessions.sole
    attempt = AccountPlanCheckoutAttempt.sole
    assert_equal "https://checkout.stripe.com/c/pay/cs_test_1", url
    assert_equal attempt.idempotency_key, opts[:idempotency_key]
    assert_equal "subscription", params[:mode]
    assert_equal "cus_1", params[:customer]
    assert_equal [ { price: COLLEAGUES_PRICE, quantity: 1 } ], params[:line_items]
    metadata = { kind: "account_plan", account_id: @account.id.to_s, plan: "colleagues", checkout_attempt: attempt.idempotency_key }
    assert_equal metadata, params[:metadata]
    assert_equal metadata, params.dig(:subscription_data, :metadata)
    assert_equal({ enabled: true }, params[:automatic_tax])
    assert_equal({ enabled: true }, params[:tax_id_collection])
    assert_equal "required", params[:billing_address_collection]
    assert_equal({ address: "auto", name: "auto" }, params[:customer_update])
    assert_equal "colleagues", attempt.plan
    assert_equal COLLEAGUES_PRICE, attempt.stripe_price_id
  end

  test "the same plan again reuses the open session; another plan replaces it" do
    first = checkout("partners")
    assert_equal first, checkout("partners")
    assert_equal 1, @stripe.checkout_sessions.size

    checkout("colleagues")
    assert_equal [ "cs_test_1" ], @stripe.expired_sessions
    assert_equal 1, AccountPlanCheckoutAttempt.unresolved.count
    assert_equal "colleagues", AccountPlanCheckoutAttempt.unresolved.sole.plan
  end

  test "an uncertain create is replayed under its key, never made twice" do
    @stripe.fail_next_checkout_create(created: true)
    assert_raises(Stripe::APIConnectionError) { checkout }
    assert_equal 1, @stripe.checkout_sessions.size
    checkout
    assert_equal 1, @stripe.checkout_sessions.size, "the replay returned the session Stripe made"
  end

  test "refused while a plan is live, a completed session is still confirming, or for Companions" do
    AccountSubscription.create!(account: @account, stripe_subscription_id: "sub_a", plan: "partners", stripe_status: "active")
    assert_raises(Billing::AlreadySubscribed) { checkout("colleagues") }
    AccountSubscription.sole.update!(stripe_status: "canceled")

    checkout("partners")
    @stripe.session_states["cs_test_1"][:status] = "complete"
    @stripe.session_states["cs_test_1"][:subscription] = "sub_b"
    error = assert_raises(Billing::AlreadySubscribed) { checkout("colleagues") }
    assert_match(/still being confirmed/, error.message)

    assert_raises(Billing::AccountPlanCheckout::Refused) { checkout("companions") }
    assert_equal 1, @stripe.checkout_sessions.size
  end

  test "a plan with no Stripe price can't be bought" do
    ENV["STRIPE_PRICE_ACCOUNT_PARTNERS"] = nil
    assert_raises(Billing::NotConfigured) { checkout("partners") }
    assert_empty @stripe.checkout_sessions
  end

end
