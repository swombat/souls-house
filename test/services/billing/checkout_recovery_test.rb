require "test_helper"
require "support/fake_stripe"

class Billing::CheckoutRecoveryTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    @agent = agents(:research_assistant)
    @stripe = FakeStripe.new
    @params = {
      mode: "subscription", customer: "cus_recovery", client_reference_id: @agent.id.to_s,
      metadata: { agent_id: @agent.id.to_s, account_id: @agent.account_id.to_s, checkout_attempt: "attempt-test" },
      line_items: [ { price: LIFE_PRICE, quantity: 1 } ]
    }
    @attempt = BillingCheckoutAttempt.create!(agent: @agent, account: @agent.account, tier: "life", rate: "standard",
      stripe_price_id: LIFE_PRICE, idempotency_key: "attempt-test", create_params: @params)
    @session = @stripe.checkout.sessions.create(@params, { idempotency_key: "attempt-test" })
  end

  def attach!(**options)
    Billing::CheckoutLock.stub(:synchronize, ->(_agent, &operation) { operation.call }) do
      Billing::CheckoutRecovery.attach!(attempt: @attempt, session_id: @session.id,
        operator: "synthetic operator", reason: "accepted create with lost response", client: @stripe, **options)
    end
  end

  test "binding a discovered session audits the operator without resolving it or granting anything" do
    attach!
    assert_equal @session.id, @attempt.reload.stripe_session_id
    assert_nil @attempt.resolved_at
    assert_empty ResidentSubscription.where(agent: @agent)
    audit = AuditLog.find_by!(action: "billing_checkout_reconciled", auditable: @agent)
    assert_equal @attempt.id, audit.data["attempt_id"]
    assert_equal "synthetic operator", audit.data["operator"]
  end

  test "another customer resident or attempt cannot be bound" do
    [ [ :customer, "cus_foreign" ], [ :client_reference_id, "foreign" ],
      [ :metadata, { "checkout_attempt" => "different" } ] ].each do |key, value|
      original = @stripe.session_states[@session.id][key]
      @stripe.session_states[@session.id][key] = value
      assert_raises(Billing::InvalidSubscription) { attach! }
      assert_nil @attempt.reload.stripe_session_id
      @stripe.session_states[@session.id][key] = original
    end
    assert_empty AuditLog.where(action: "billing_checkout_reconciled")
  end

  test "an operator must give an identity and reason" do
    assert_raises(ArgumentError) { attach!(operator: "") }
    assert_raises(ArgumentError) { attach!(reason: "") }
    assert_nil @attempt.reload.stripe_session_id
  end

  test "the SDK clients inherit bounded timeouts without retries" do
    assert_equal 3, Stripe.open_timeout
    assert_equal 8, Stripe.read_timeout
    assert_equal 8, Stripe.write_timeout
    assert_equal 0, Stripe.max_network_retries
  end

end
