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

    grant = BillingCode.redeem!(code: BillingCode.create!(code: "PEPE", effect: "at_cost", created_by: users(:site_admin_user)).code,
      account: @agent.account, by: users(:user_1))
    checkout(rate: "at_cost")
    params, opts = @stripe.checkout_sessions.last
    assert_equal "souls-house-checkout-#{@agent.id}-cs_test_1-life_at_cost", opts[:idempotency_key]
    assert_equal [ { price: LIFE_AT_COST_PRICE, quantity: 1 } ], params[:line_items]
    assert_equal "at_cost", params.dig(:metadata, :rate)
    assert_equal grant.id.to_s, params.dig(:metadata, :redemption_id)
    assert_equal "Life at cost hosting for #{@agent.name}", params.dig(:subscription_data, :description)
  end

  test "an at-cost session needs a grant the account holds" do
    error = assert_raises(Billing::NotEligible) { checkout(rate: "at_cost") }
    assert_match(/can't buy plans at that rate/, error.message)
    assert_empty @stripe.checkout_sessions
  end

  # An uncertain create is replayed under the same key. The attempt, with the
  # grant it was authorised by, is committed before Stripe is called, so the
  # replay's payload matches even after the account's grants have changed.
  test "a replayed attempt sends the grant it was authorised by, whatever the grants are by then" do
    admin = users(:site_admin_user)
    first_grant = BillingCode.redeem!(code: BillingCode.create!(code: "PEPE", effect: "at_cost", created_by: admin).code,
      account: @agent.account, by: users(:user_1))
    @stripe.fail_next_checkout_create(created: true)
    assert_raises(Stripe::APIConnectionError) { checkout(rate: "at_cost") }
    attempt = CheckoutAttempt.sole
    assert_equal first_grant, attempt.billing_code_redemption
    assert_equal "life_at_cost", attempt.offer_id
    assert_nil attempt.stripe_session_id, "the answer was lost"
    assert_nil ResidentEntitlement.find_by!(agent: @agent).checkout_session_id

    first_grant.withdraw!(by: admin)
    second_grant = BillingCode.redeem!(code: BillingCode.create!(code: "PEPE-2", effect: "at_cost", created_by: admin).code,
      account: @agent.account, by: users(:user_1))
    assert_equal second_grant, @agent.account.grant_for("at_cost")

    assert_equal "https://checkout.stripe.com/c/pay/cs_test_1", checkout(rate: "at_cost")
    assert_equal 1, @stripe.checkout_sessions.size, "the replay found the session Stripe had made"
    assert_equal first_grant.id.to_s, @stripe.checkout_sessions.sole.first.dig(:metadata, :redemption_id)
    assert_equal "cs_test_1", attempt.reload.stripe_session_id
    assert_equal "cs_test_1", ResidentEntitlement.find_by!(agent: @agent).checkout_session_id
    assert_equal 1, CheckoutAttempt.count
  end

  test "an attempt Stripe never made is recoverable too: the next call makes it under the same key" do
    @stripe.fail_next_checkout_create(created: false)
    assert_raises(Stripe::APIConnectionError) { checkout }
    attempt = CheckoutAttempt.sole
    assert_nil attempt.stripe_session_id

    checkout
    assert_equal 1, @stripe.checkout_sessions.size
    assert_equal attempt.idempotency_key, @stripe.checkout_sessions.sole.last[:idempotency_key]
    assert_equal "cs_test_1", attempt.reload.stripe_session_id
  end

  # Mira's edge on #626: an attempt at another offer must not overwrite an
  # unresolved one, nor leave its session open at Stripe.
  test "before an attempt at another offer, an unresolved attempt is recovered and its session expired" do
    admin = users(:site_admin_user)
    grant = BillingCode.redeem!(code: BillingCode.create!(code: "PEPE", effect: "at_cost", created_by: admin).code,
      account: @agent.account, by: users(:user_1))
    @stripe.fail_next_checkout_create(created: true)
    assert_raises(Stripe::APIConnectionError) { checkout(rate: "at_cost") }
    unresolved = CheckoutAttempt.sole

    assert_equal "https://checkout.stripe.com/c/pay/cs_test_2", checkout

    assert_equal "cs_test_1", unresolved.reload.stripe_session_id, "replayed by its key to learn its session"
    assert_equal grant, unresolved.billing_code_redemption
    assert_includes @stripe.expired_sessions, "cs_test_1"
    standard = CheckoutAttempt.where.not(id: unresolved.id).sole
    assert_equal "life", standard.offer_id
    assert_equal "cs_test_2", standard.stripe_session_id
    assert_equal "cs_test_2", ResidentEntitlement.find_by!(agent: @agent).checkout_session_id
  end

  test "an unresolved attempt whose key Stripe refuses to replay is abandoned, not retried forever" do
    admin = users(:site_admin_user)
    BillingCode.redeem!(code: BillingCode.create!(code: "PEPE", effect: "at_cost", created_by: admin).code,
      account: @agent.account, by: users(:user_1))
    @stripe.fail_next_checkout_create(created: true)
    assert_raises(Stripe::APIConnectionError) { checkout(rate: "at_cost") }
    unresolved = CheckoutAttempt.sole
    # Its payload can no longer be rebuilt: the session's stored parameters differ.
    @stripe.session_states["cs_test_1"][:create_params][:success_url] = "https://elsewhere.example"

    assert_equal "https://checkout.stripe.com/c/pay/cs_test_2", checkout
    assert unresolved.reload.abandoned_at.present?
    assert_nil unresolved.stripe_session_id
  end

  test "a replay of the same offer that Stripe refuses abandons the attempt, and the next request gets a fresh key" do
    @stripe.fail_next_checkout_create(created: true)
    assert_raises(Stripe::APIConnectionError) { checkout }
    first = CheckoutAttempt.sole
    @stripe.session_states["cs_test_1"][:create_params][:cancel_url] = "https://elsewhere.example"

    error = assert_raises(Billing::NotReady) { checkout }
    assert_match(/couldn't be reconciled/, error.message)
    assert first.reload.abandoned_at.present?

    assert_equal "https://checkout.stripe.com/c/pay/cs_test_2", checkout
    fresh = CheckoutAttempt.where.not(id: first.id).sole
    assert_equal "#{first.idempotency_key}-retry-1", fresh.idempotency_key
    assert_equal "cs_test_2", fresh.stripe_session_id
  end

end
