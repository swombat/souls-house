require "test_helper"
require "support/fake_stripe"

class Billing::CheckoutTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    @agent = agents(:research_assistant)
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @agent.account, stripe_customer_id: "cus_1")
  end

  def checkout(rate: "standard")
    Billing::Checkout.new(agent: @agent, tier: Billing::Tier.find!("life"), rate: rate, client: @stripe,
      success_url: "https://souls.example/ok", cancel_url: "https://souls.example/no").url
  end

  # The key is deterministic across deploys, so the standard payload must not
  # move when rates arrive.
  test "a standard session's payload and key are the pre-rates ones" do
    checkout
    params, opts = @stripe.checkout_sessions.sole
    assert_equal "souls-house-checkout-#{@agent.id}-first-life", opts[:idempotency_key]
    assert_equal [ { price: LIFE_PRICE, quantity: 1 } ], params[:line_items]
    assert_equal({ agent_id: @agent.id.to_s, account_id: @agent.account_id.to_s, tier: "life" }, params[:metadata])
    assert_equal "Life hosting for #{@agent.name}", params.dig(:subscription_data, :description)
  end

  # Moving an existing resident to at cost needs the Checkout attempt
  # lifecycle designed (recovery of an uncertain create under contention with
  # other offers); until then it is refused, with or without a grant, and a
  # new resident is created at cost through the wizard.
  test "an existing resident is not moved to at cost yet, grant or no grant" do
    error = assert_raises(Billing::NotEligible) { checkout(rate: "at_cost") }
    assert_match(/is coming/, error.message)

    BillingCode.redeem!(code: BillingCode.create!(code: "PEPE", effect: "at_cost", created_by: users(:site_admin_user)).code,
      account: @agent.account, by: users(:user_1))
    assert_raises(Billing::NotEligible) { checkout(rate: "at_cost") }
    assert_empty @stripe.checkout_sessions
  end

end
