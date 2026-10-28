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
  # move when rates arrive; only an at-cost session says its rate.
  test "a standard session's payload and key are the pre-rates ones; an at-cost session carries its rate" do
    checkout
    params, opts = @stripe.checkout_sessions.sole
    assert_equal "souls-house-checkout-#{@agent.id}-first-life", opts[:idempotency_key]
    assert_equal [ { price: LIFE_PRICE, quantity: 1 } ], params[:line_items]
    assert_equal({ agent_id: @agent.id.to_s, account_id: @agent.account_id.to_s, tier: "life" }, params[:metadata])
    assert_equal "Life hosting for #{@agent.name}", params.dig(:subscription_data, :description)

    checkout(rate: "at_cost")
    params, opts = @stripe.checkout_sessions.last
    assert_equal "souls-house-checkout-#{@agent.id}-cs_test_1-life_at_cost", opts[:idempotency_key]
    assert_equal [ { price: LIFE_AT_COST_PRICE, quantity: 1 } ], params[:line_items]
    assert_equal "at_cost", params.dig(:metadata, :rate)
    assert_equal "Life at cost hosting for #{@agent.name}", params.dig(:subscription_data, :description)
  end

end
