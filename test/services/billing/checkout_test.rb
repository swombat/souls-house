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

  test "a first bill's session pins the plan and its included resident, metadata and payload on a unique attempt" do
    checkout
    params, opts = @stripe.checkout_sessions.sole
    pin = BillingCheckoutAttempt.find_by!(agent: @agent)
    assert_equal pin.idempotency_key, opts[:idempotency_key]
    # The plan includes its resident: a Medium is the plan's own at $30.
    assert_equal [ { price: COMPANIONS_PRICE, quantity: 1 }, { price: LIFE_INCLUDED_PRICE, quantity: 1 } ], params[:line_items]
    assert_equal [ "included", LIFE_INCLUDED_PRICE ], [ pin.rate, pin.stripe_price_id ]
    assert_equal @agent.id.to_s, params.dig(:metadata, :agent_id)
    assert_equal @agent.account_id.to_s, params.dig(:metadata, :account_id)
    assert_equal "life", params.dig(:metadata, :tier)
    assert_equal pin.idempotency_key, params.dig(:metadata, :checkout_attempt)
    assert_equal "included", params.dig(:metadata, :rate)
    assert_equal "companions", params.dig(:metadata, :plan)
    assert_nil params.dig(:metadata, :redemption_id)
    assert_equal "Companions plan, including #{@agent.name} (Medium)", params.dig(:subscription_data, :description)
    assert_not params.key?(:expires_at), "Expiry must be relative to Stripe execution, not the intent commit"
    assert_equal JSON.parse(params.to_json), pin.create_params
  end

  test "an open Checkout is reused only while its plan line is still the one the first bill would carry" do
    checkout
    first = BillingCheckoutAttempt.find_by!(agent: @agent)
    assert_equal "companions", first.create_params.dig("metadata", "plan")
    @agent.account.update!(chosen_plan: "partners")
    checkout
    assert_equal [ "expired" ], @stripe.expired_sessions.map { |id| @stripe.session_states[id][:status] }.uniq
    assert_equal "partners", BillingCheckoutAttempt.unresolved.find_by!(agent: @agent).create_params.dig("metadata", "plan")
  end

  test "an open first-bill Checkout for one resident means another resident is not the included one" do
    checkout
    other = agents(:code_reviewer)
    assert_not Billing::Included.available?(@agent.account), "the open Checkout already carries the included resident"
    assert Billing::Included.available?(@agent.account, except_agent: @agent), "control: not counting its own resident"
    assert_equal "standard", Billing::Included.offer_for(@agent.account, Billing::Tier.find!("conversation").offer).rate
    assert_equal @agent.account, other.account
  end

  test "a Checkout Stripe has expired stops holding the included resident and plan codes; one still open or uncertain keeps them" do
    checkout
    account = @agent.account
    attempt = BillingCheckoutAttempt.unresolved.find_by!(agent: @agent)
    assert_not Billing::Included.available?(account)
    assert BillingCode.new.send(:first_bill_with_plan_open?, account)

    Billing::Checkout.release_expired!(account, client: @stripe)
    assert_nil attempt.reload.resolved_at, "an open session still holds them"

    @stripe.v1.checkout.sessions.expire(attempt.stripe_session_id)
    uncertain = BillingCheckoutAttempt.create!(agent: agents(:code_reviewer), account:, tier: "conversation",
      rate: "included", stripe_price_id: CONVERSATION_INCLUDED_PRICE, idempotency_key: "key-uncertain",
      create_params: { "metadata" => { "plan" => "companions" } })
    Billing::Checkout.release_expired!(account, client: @stripe)
    assert attempt.reload.resolved_at, "Stripe says expired: released"
    assert_nil uncertain.reload.resolved_at, "no session yet: it may still be payable, so it is kept"
    assert_not Billing::Included.available?(account), "the uncertain one still holds the included resident"

    uncertain.update!(resolved_at: Time.current)
    assert Billing::Included.available?(account)
    assert_not BillingCode.new.send(:first_bill_with_plan_open?, account)
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

  test "the Hetzner at-cost rate is never sold through Checkout, even to an account with an at-cost code" do
    grant!
    error = assert_raises(Billing::NotEligible) { checkout(rate: "at_cost_hetzner") }
    assert_equal "That rate is set by the house, not bought.", error.message
    assert_empty @stripe.checkout_sessions
    assert_empty BillingCheckoutAttempt.where(agent: @agent)
  end

  test "completed with the payment still to come, then paid: the attempt holds until its subscription comes in" do
    checkout
    account = @agent.account
    attempt = BillingCheckoutAttempt.unresolved.find_by!(agent: @agent)
    @stripe.complete_checkout_session(attempt.stripe_session_id, subscription_id: "sub_slow", payment_status: "unpaid")
    Billing::Checkout.release_expired!(account, client: @stripe)
    assert_nil attempt.reload.resolved_at, "an unpaid session may still be paid"
    assert_not Billing::Included.available?(account)

    @stripe.set_subscription_status("sub_slow", "active")
    Billing::Checkout.release_expired!(account, client: @stripe)
    assert_nil attempt.reload.resolved_at, "paid is not ended unpaid: the sweep leaves it to BillSync"
    Billing::BillSync.new("sub_slow", client: @stripe).call
    assert attempt.reload.resolved_at
    assert ResidentSubscription.live.exists?(agent: @agent)
  end

  test "completed with the payment still to come, then ended unpaid: the sweep releases it and a new Checkout replaces it" do
    checkout
    account = @agent.account
    attempt = BillingCheckoutAttempt.unresolved.find_by!(agent: @agent)
    @stripe.complete_checkout_session(attempt.stripe_session_id, subscription_id: "sub_slow", payment_status: "unpaid")
    @stripe.set_subscription_status("sub_slow", "past_due")
    Billing::Checkout.release_expired!(account, client: @stripe)
    assert_nil attempt.reload.resolved_at, "only incomplete_expired ends it"

    @stripe.set_subscription_status("sub_slow", "incomplete_expired")
    Billing::Checkout.release_expired!(account, client: @stripe)
    assert attempt.reload.resolved_at
    assert Billing::Included.available?(account)
    checkout
    assert_equal 2, @stripe.checkout_sessions.size
    assert BillingCheckoutAttempt.unresolved.find_by!(agent: @agent).stripe_session_id.present?
  end

  test "a new Checkout replaces one Stripe ended unpaid even when the sweep didn't see it" do
    checkout
    attempt = BillingCheckoutAttempt.unresolved.find_by!(agent: @agent)
    @stripe.complete_checkout_session(attempt.stripe_session_id, subscription_id: "sub_slow", payment_status: "unpaid")
    @stripe.set_subscription_status("sub_slow", "incomplete_expired")
    Billing::CheckoutSession.stub(:release_expired!, nil) { checkout(tier: "work") }
    assert attempt.reload.resolved_at, "settle! decided it"
    assert_equal "work", BillingCheckoutAttempt.unresolved.find_by!(agent: @agent).tier
  end

  test "a new Checkout still refuses while a completed session's payment is undecided" do
    checkout
    attempt = BillingCheckoutAttempt.unresolved.find_by!(agent: @agent)
    @stripe.complete_checkout_session(attempt.stripe_session_id, subscription_id: "sub_slow", payment_status: "unpaid")
    assert_raises(Billing::AlreadySubscribed) { checkout(tier: "work") }
    assert_nil attempt.reload.resolved_at
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
    @stripe.session_states["cs_legacy"] = { customer: "cus_1", status: "complete", payment_status: "paid", subscription: "sub_unknown",
      mode: "subscription", client_reference_id: @agent.id.to_s }
    assert_raises(Billing::AlreadySubscribed) { checkout }
    assert_empty @stripe.checkout_sessions
    assert_empty BillingCheckoutAttempt.where(agent: @agent)
  end

  test "a create lost before acceptance can first execute two hours later" do
    @stripe.fail_next_checkout_create(created: false)
    assert_raises(Stripe::APIConnectionError) { checkout }
    pin = BillingCheckoutAttempt.find_by!(agent: @agent)
    original = pin.create_params.deep_dup
    assert_empty @stripe.session_states

    travel 2.hours do
      assert_match %r{https://}, checkout
      assert_equal original, pin.reload.create_params
      assert_not original.key?("expires_at")
      assert_equal 1, BillingCheckoutAttempt.where(agent: @agent).count
      assert_equal "open", @stripe.session_states.fetch(pin.stripe_session_id)[:status]
    end
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
