require "test_helper"
require "support/fake_stripe"

class Billing::PaymentMethodTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    @account = accounts(:personal_account)
    @stripe = FakeStripe.new
  end

  def payment_method = Billing::PaymentMethod.new(account: @account, client: @stripe)

  test "an account with no customer or no saved card has no card" do
    assert_nil payment_method.current
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    assert_nil payment_method.current
  end

  test "the saved card is summarised, never more" do
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    @stripe.put_payment_method("pm_1", brand: "visa", last4: "4242", exp_month: 3, exp_year: 2031)
    @stripe.put_customer("cus_1", default_payment_method: "pm_1")

    assert_equal({ brand: "visa", last4: "4242", exp_month: 3, exp_year: 2031 }, payment_method.current.as_json)
  end

  test "the card form saves a card without charging, and its card becomes the account's" do
    started = payment_method.start_setup!
    params, = @stripe.checkout_sessions.sole
    assert_equal "setup", params[:mode]
    assert_equal "embedded_page", params[:ui_mode]
    assert_equal "never", params[:redirect_on_completion]
    assert_equal "required", params[:billing_address_collection]
    assert_equal "cs_test_1_secret", started[:client_secret]

    assert_raises(Billing::NotReady) { payment_method.finish_setup!(started[:session_id]) }

    @stripe.complete_setup_session(started[:session_id], payment_method: "pm_new")
    saved = payment_method.finish_setup!(started[:session_id])
    assert_equal "pm_new", saved.id
    customer_id = BillingCustomer.find_by!(account: @account).stripe_customer_id
    assert_equal [ [ customer_id, { invoice_settings: { default_payment_method: "pm_new" } } ] ], @stripe.customer_updates
  end

  test "another account's card form can't be finished here" do
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    @stripe.checkout.sessions.create({ mode: "setup", customer: "cus_someone_else" })
    @stripe.complete_setup_session("cs_test_1", payment_method: "pm_theirs")

    assert_raises(Billing::InvalidSubscription) { payment_method.finish_setup!("cs_test_1") }
    assert_empty @stripe.customer_updates
  end

end
