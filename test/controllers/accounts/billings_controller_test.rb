require "test_helper"
require "support/fake_stripe"

class Accounts::BillingsControllerTest < ActionDispatch::IntegrationTest

  include FakeStripe::Helpers

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @stripe = FakeStripe.new
    Setting.instance.update!(allow_agents: true)
    sign_in(@user)
  end

  test "the owner moves a paid resident to another plan from the Billing tab" do
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    @stripe.put_subscription(id: "sub_1", agent: @agent, customer: "cus_1", price: CONVERSATION_PRICE, status: "active")
    with_stripe do
      Billing::SubscriptionSync.new("sub_1", client: @stripe).call
      post plan_change_account_billing_path(@account), params: { agent_id: @agent.to_param, tier: "life" }
    end

    assert_redirected_to account_billing_path(@account)
    assert_match(/now on Medium/, flash[:notice])
    assert_equal "life", ResidentEntitlement.find_by!(agent: @agent).tier
    assert AuditLog.exists?(action: "change_plan", user: @user)

    get account_billing_path(@account)
    assert_equal %w[conversation conversation_at_cost life life_at_cost work work_at_cost],
      inertia_shared_props["change_offers"].map { |offer| offer["id"] }

    sign_in(users(:regular_user))
    with_stripe do
      post plan_change_account_billing_path(@account), params: { agent_id: @agent.to_param, tier: "work" }
    end
    assert_equal "life", ResidentEntitlement.find_by!(agent: @agent).tier, "only the owner changes plans"
  end

  test "shows each hosted resident's plan and the catalogue" do
    ResidentEntitlement.create!(agent: @agent, account: @account, source: "complimentary",
      state: "complimentary", complimentary_granted_at: Time.current)

    get account_billing_path(@account)

    assert_response :success
    assert_equal "accounts/billing", inertia_component
    props = inertia_shared_props
    assert props.dig("billing", "configured")
    assert props.dig("billing", "can_pay")
    assert_match(/@/, props.dig("billing", "contact_email"))
    assert_equal %w[conversation life work], props["tiers"].map { |tier| tier["id"] }
    assert_equal "9.99", props["tiers"].first["monthly_usd"]
    resident = props["residents"].find { |row| row["id"] == @agent.to_param }
    assert_equal "complimentary", resident.dig("entitlement", "state")
    assert_equal Billing::AccountPlan.all.as_json.map(&:deep_stringify_keys), props["account_plans"]
    assert_equal({ "id" => "companions", "source" => "default", "subscription" => nil }, props["account_plan"])
  end

  test "the account plan prop names its source and the live subscription" do
    @account.update!(granted_plan: "partners")
    get account_billing_path(@account)
    assert_equal({ "id" => "partners", "source" => "grant", "subscription" => nil }, inertia_shared_props["account_plan"])

    AccountSubscription.create!(account: @account, stripe_subscription_id: "sub_a", plan: "colleagues",
      stripe_status: "active", current_period_end: Time.utc(2026, 12, 10), cancel_at_period_end: true)
    get account_billing_path(@account)
    assert_equal({ "id" => "colleagues", "source" => "subscription",
      "subscription" => { "status" => "active", "current_period_end" => "2026-12-10T00:00:00Z", "cancel_at_period_end" => true } },
      inertia_shared_props["account_plan"])
  end

  test "the owner buys an account plan through Checkout, audited; a member can't" do
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    with_stripe do
      post account_plan_checkout_account_billing_path(@account), params: { plan: "partners" }, headers: { "X-Inertia" => "true" }
    end
    assert_response :conflict
    assert_equal "https://checkout.stripe.com/c/pay/cs_test_1", response.headers["X-Inertia-Location"]
    params, = @stripe.checkout_sessions.sole
    assert_equal "account_plan", params.dig(:metadata, :kind)
    assert AuditLog.exists?(action: "start_account_plan_checkout", user: @user)

    with_stripe do
      post account_plan_checkout_account_billing_path(@account), params: { plan: "companions" }
    end
    assert_redirected_to account_billing_path(@account)
    assert_match(/Companions comes with every account/, flash[:alert])

    sign_in(users(:regular_user))
    with_stripe { post account_plan_checkout_account_billing_path(@account), params: { plan: "colleagues" } }
    assert_equal 1, @stripe.checkout_sessions.size, "only the owner pays"
  end

  test "the owner moves the account between Partners and Colleagues, audited" do
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    @stripe.put_account_subscription(id: "sub_a", account: @account, customer: "cus_1", price: PARTNERS_PRICE, status: "active")
    with_stripe do
      Billing::SubscriptionSync.new("sub_a", client: @stripe).call
      post account_plan_change_account_billing_path(@account), params: { plan: "colleagues" }
    end
    assert_redirected_to account_billing_path(@account)
    assert_match(/now on Colleagues/, flash[:notice])
    assert_equal "colleagues", @account.reload.plan.id
    audit = AuditLog.find_by!(action: "change_account_plan", user: @user)
    assert_equal "colleagues", audit.data["now"]

    with_stripe { post account_plan_change_account_billing_path(@account), params: { plan: "colleagues" } }
    assert_match(/already on Colleagues/, flash[:alert])
  end

  test "disabled residents are left off the list and can't be checked out" do
    @agent.update!(active: false)

    get account_billing_path(@account)

    assert_response :success
    assert_nil inertia_shared_props["residents"].find { |row| row["id"] == @agent.to_param }

    with_stripe do
      post checkout_account_billing_path(@account), params: { agent_id: @agent.to_param, tier: "conversation" },
        headers: { "X-Inertia" => "true" }
    end
    assert_response :not_found
    assert_empty @stripe.checkout_sessions
  end

  test "checkout sends the owner to Stripe with tax, VAT ID collection and the resident in metadata" do
    with_stripe do
      post checkout_account_billing_path(@account), params: { agent_id: @agent.to_param, tier: "conversation" },
        headers: { "X-Inertia" => "true" }
    end

    assert_response :conflict
    assert_equal "https://checkout.stripe.com/c/pay/cs_test_1", response.headers["X-Inertia-Location"]
    params, opts = @stripe.checkout_sessions.sole
    assert_equal "subscription", params[:mode]
    assert_equal [ { price: FakeStripe::Helpers::CONVERSATION_PRICE, quantity: 1 } ], params[:line_items]
    assert_equal @agent.id.to_s, params.dig(:subscription_data, :metadata, :agent_id)
    assert params.dig(:automatic_tax, :enabled)
    assert params.dig(:tax_id_collection, :enabled)
    assert_equal BillingCheckoutAttempt.find_by!(agent: @agent).idempotency_key, opts[:idempotency_key]
    assert_equal "cus_test_1", BillingCustomer.find_by!(account: @account).stripe_customer_id
    assert ResidentEntitlement.find_by!(agent: @agent).pending?
  end

  def start_checkout(tier)
    with_stripe do
      post checkout_account_billing_path(@account), params: { agent_id: @agent.to_param, tier: tier },
        headers: { "X-Inertia" => "true" }
    end
  end

  test "a second checkout, for another plan or the same one later, expires the first so only one can be paid" do
    start_checkout("conversation")
    travel 2.hours do
      start_checkout("life")
    end

    assert_equal [ "cs_test_1" ], @stripe.expired_sessions
    assert_equal "expired", @stripe.session_states.dig("cs_test_1", :status)
    assert_equal "open", @stripe.session_states.dig("cs_test_2", :status)
    assert_equal "cs_test_2", ResidentEntitlement.find_by!(agent: @agent).checkout_session_id
    assert_equal 2, @stripe.checkout_sessions.map { |_params, options| options[:idempotency_key] }.uniq.size
  end

  test "a paid checkout the webhook hasn't confirmed yet blocks a new one" do
    start_checkout("conversation")
    @stripe.session_states["cs_test_1"] = { status: "complete", subscription: "sub_pending" }

    start_checkout("life")

    assert_redirected_to account_billing_path(@account)
    assert_match(/still being confirmed/, flash[:alert])
    assert_equal 1, @stripe.checkout_sessions.size
    assert_empty @stripe.expired_sessions
  end

  test "once that paid subscription has ended, a new checkout is allowed" do
    start_checkout("conversation")
    @stripe.session_states["cs_test_1"] = { status: "complete", subscription: "sub_old" }
    ResidentSubscription.create!(agent: @agent, account: @account, stripe_subscription_id: "sub_old",
      tier: "conversation", stripe_status: "canceled")

    start_checkout("life")

    assert_response :conflict
    assert_equal 2, @stripe.checkout_sessions.size
  end

  test "checkout refuses a resident that already has a live subscription" do
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    ResidentSubscription.create!(agent: @agent, account: @account, stripe_subscription_id: "sub_1",
      tier: "conversation", stripe_status: "active")

    with_stripe do
      post checkout_account_billing_path(@account), params: { agent_id: @agent.to_param, tier: "life" }
    end

    assert_redirected_to account_billing_path(@account)
    assert_match(/already has a subscription/, flash[:alert])
    assert_empty @stripe.checkout_sessions
  end

  test "the portal opens for the account's Stripe customer" do
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")

    with_stripe do
      post portal_account_billing_path(@account), headers: { "X-Inertia" => "true" }
    end

    assert_response :conflict
    assert_equal "https://billing.stripe.com/p/session/test_1", response.headers["X-Inertia-Location"]
    assert_equal "cus_1", @stripe.portal_sessions.sole[:customer]
  end

  test "another account's residents and billing are out of reach" do
    get account_billing_path(accounts(:other))
    assert_response :not_found
  end

  private

  # Controller contract tests keep fixture transactions; actual committed-intent
  # and PostgreSQL lock behavior is exercised in CheckoutLifecycleTest.
  def with_stripe(&block)
    Billing.stub(:client, @stripe) do
      Billing::CheckoutLock.stub(:synchronize, ->(_agent, &operation) { operation.call }) do
        Billing::CheckoutLock.stub(:synchronize_account, ->(_account, &operation) { operation.call }, &block)
      end
    end
  end

end
