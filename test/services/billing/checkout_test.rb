require "test_helper"
require "support/fake_stripe"

class Billing::CheckoutTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    @agent = agents(:research_assistant)
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @agent.account, stripe_customer_id: "cus_1")
  end

  def checkout(rate: "standard", tier: "life")
    # Unit contracts below use fixture transactions; durable commit/lock tests
    # live in CheckoutLifecycleTest with transactional tests disabled.
    Billing::CheckoutLock.stub(:synchronize, ->(_agent, &operation) { operation.call }) do
      Billing::Checkout.new(agent: @agent, tier: Billing::Tier.find!(tier), rate: rate, client: @stripe,
        success_url: "https://souls.example/ok", cancel_url: "https://souls.example/no").url
    end
  end

  def grant!
    BillingCode.redeem!(code: BillingCode.create!(code: "PEPE", effect: "at_cost", created_by: users(:site_admin_user)).code,
      account: @agent.account, by: users(:user_1))
  end

  test "a standard session pins its exact price metadata and payload on a unique attempt" do
    checkout
    params, opts = @stripe.checkout_sessions.sole
    pin = BillingCheckoutAttempt.find_by!(agent: @agent)
    assert_equal pin.idempotency_key, opts[:idempotency_key]
    assert_equal [ { price: LIFE_PRICE, quantity: 1 } ], params[:line_items]
    assert_equal @agent.id.to_s, params.dig(:metadata, :agent_id)
    assert_equal @agent.account_id.to_s, params.dig(:metadata, :account_id)
    assert_equal "life", params.dig(:metadata, :tier)
    assert_equal pin.idempotency_key, params.dig(:metadata, :checkout_attempt)
    assert_nil params.dig(:metadata, :rate)
    assert_equal "Life hosting for #{@agent.name}", params.dig(:subscription_data, :description)
    assert_in_delta 1.hour.from_now.to_i, params[:expires_at], 2
    assert_equal JSON.parse(params.to_json), pin.create_params
  end

  test "at cost requires a grant and tells a house-model owner where to change models" do
    assert_raises(Billing::NotEligible) { checkout(rate: "at_cost") }
    grant!
    @agent.update_columns(model_id: HouseInference::Offering::DEEPSEEK_MODEL_ID)
    error = assert_raises(Billing::NotEligible) { checkout(rate: "at_cost") }
    assert_match(/resident's settings first/, error.message)
    assert_empty @stripe.checkout_sessions
    assert_empty BillingCheckoutAttempt.where(agent: @agent)
  end

  test "an eligible resident buys at cost without changing its complimentary entitlement" do
    redemption = grant!
    entitlement = ResidentEntitlement.create!(agent: @agent, account: @agent.account, source: "complimentary",
      state: "complimentary", complimentary_granted_at: Time.current)
    original = entitlement.attributes.except("checkout_session_id", "updated_at")
    checkout(rate: "at_cost")
    params = @stripe.checkout_sessions.sole.first
    assert_equal LIFE_AT_COST_PRICE, params[:line_items].sole[:price]
    assert_equal "at_cost", params.dig(:subscription_data, :metadata, :rate)
    assert_equal redemption.id.to_s, params.dig(:subscription_data, :metadata, :redemption_id)
    assert_equal original, entitlement.reload.attributes.except("checkout_session_id", "updated_at")
    assert_empty ResidentSubscription.where(agent: @agent)
  end

  test "same offer returns its open session rather than creating another link" do
    first = checkout
    assert_equal first, checkout
    assert_equal 1, @stripe.checkout_sessions.size
    assert_empty @stripe.expired_sessions
  end

  test "failed expiry blocks replacement and leaves the previous attempt unresolved" do
    checkout
    sessions = @stripe.checkout.sessions
    @stripe.stub(:checkout, Struct.new(:sessions).new(sessions)) do
      sessions.stub(:expire, ->(*) { raise Stripe::APIConnectionError, "expiry answer lost" }) do
        assert_raises(Stripe::APIConnectionError) { checkout(tier: "work") }
      end
    end
    assert_equal 1, @stripe.checkout_sessions.size
    assert_nil BillingCheckoutAttempt.find_by!(agent: @agent).resolved_at
  end

  test "legacy unknown accepts are found beyond page one and expired before creating an attempt" do
    101.times do |index|
      @stripe.session_states["cs_other_#{index}"] = { customer: "cus_1", status: "open",
        mode: "subscription", client_reference_id: "unrelated" }
    end
    @stripe.session_states["cs_legacy"] = { customer: "cus_1", status: "open",
      mode: "subscription", client_reference_id: @agent.id.to_s }
    checkout
    assert_equal [ "cs_legacy" ], @stripe.expired_sessions
    assert_equal 1, @stripe.checkout_sessions.size
  end

  test "a legacy paid unknown blocks instead of starting a new attempt" do
    @stripe.session_states["cs_legacy"] = { customer: "cus_1", status: "complete", subscription: "sub_unknown",
      mode: "subscription", client_reference_id: @agent.id.to_s }
    assert_raises(Billing::AlreadySubscribed) { checkout }
    assert_empty @stripe.checkout_sessions
    assert_empty BillingCheckoutAttempt.where(agent: @agent)
  end

  test "an expired cached create response is not published as an open link" do
    @stripe.fail_next_checkout_create(created: true)
    assert_raises(Stripe::APIConnectionError) { checkout }
    @stripe.session_states["cs_test_1"][:status] = "expired"
    checkout
    assert_equal 2, @stripe.checkout_sessions.size
    assert_equal "cs_test_2", ResidentEntitlement.find_by!(agent: @agent).checkout_session_id
    assert BillingCheckoutAttempt.find_by!(stripe_session_id: "cs_test_1").resolved_at
  end

end
