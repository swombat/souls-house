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

  test "with a live subscription, choosing a plan shows the quote and confirming adds the resident to it" do
    second = agents(:code_reviewer)
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    @stripe.put_payment_method("pm_1")
    @stripe.put_customer("cus_1", default_payment_method: "pm_1")
    @stripe.put_shared_subscription(id: "sub_acct", account: @account, customer: "cus_1", status: "active",
      items: [ { agent: @agent, price: LIFE_PRICE, id: "si_a" } ])
    with_stripe do
      Billing::SubscriptionSync.new("sub_acct", client: @stripe).call
      post checkout_account_billing_path(@account), params: { agent_id: second.to_param, tier: "conversation" }
    end

    attempt = BillingCheckoutAttempt.find_by!(agent: second, kind: "item")
    assert_redirected_to account_billing_path(@account, add: attempt.id)
    assert_empty @stripe.checkout_sessions, "no second subscription is opened"
    assert_empty @stripe.subscription_updates, "nothing changes before the owner confirms"

    get account_billing_path(@account, add: attempt.id)
    shown = inertia_shared_props["pending_add"]
    assert_equal [ second.name, Billing::AddItem.digest(attempt.quote) ], shown.values_at("resident_name", "digest")

    sign_in(users(:regular_user))
    with_stripe do
      post add_resident_account_billing_path(@account), params: { attempt_id: attempt.id, digest: shown["digest"] }
    end
    assert_empty @stripe.subscription_updates, "only the owner adds a resident"

    sign_in(@user)
    with_stripe do
      post add_resident_account_billing_path(@account), params: { attempt_id: attempt.id, digest: shown["digest"] }
    end
    assert_redirected_to account_billing_path(@account)
    assert_match(/next bill/, flash[:notice])
    assert ResidentEntitlement.find_by!(agent: second).active?
    assert_equal [ "sub_acct" ], ResidentSubscription.live.where(account: @account).distinct.pluck(:stripe_subscription_id)
    assert AuditLog.exists?(action: "add_resident_to_subscription", user: @user)
  end

  test "a stale quote is made again and shown, and a refusal says why" do
    second = agents(:code_reviewer)
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    @stripe.put_shared_subscription(id: "sub_acct", account: @account, customer: "cus_1", status: "active",
      items: [ { agent: @agent, price: LIFE_PRICE, id: "si_a" } ])
    with_stripe do
      Billing::SubscriptionSync.new("sub_acct", client: @stripe).call
      post checkout_account_billing_path(@account), params: { agent_id: second.to_param, tier: "conversation" }
    end
    assert_redirected_to account_billing_path(@account)
    assert_match(/Add a card first/, flash[:alert])

    @stripe.put_payment_method("pm_1")
    @stripe.put_customer("cus_1", default_payment_method: "pm_1")
    with_stripe { post checkout_account_billing_path(@account), params: { agent_id: second.to_param, tier: "conversation" } }
    stale = BillingCheckoutAttempt.unresolved.find_by!(agent: second, kind: "item")
    @stripe.price_amounts[CONVERSATION_PRICE] = 4_200
    with_stripe do
      post add_resident_account_billing_path(@account),
        params: { attempt_id: stale.id, digest: Billing::AddItem.digest(stale.quote) }
    end

    fresh = BillingCheckoutAttempt.unresolved.find_by!(agent: second, kind: "item")
    assert_not_equal stale.id, fresh.id
    assert_redirected_to account_billing_path(@account, add: fresh.id)
    assert_match(/price changed/, flash[:alert])
    assert_empty @stripe.subscription_updates
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

  test "the Billing tab says whether the trial is offered and when each resident's trial ends" do
    @account.update!(billing_required: true, trial_started_at: 3.days.ago)
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    @stripe.put_subscription(id: "sub_1", agent: @agent, customer: "cus_1", price: CONVERSATION_PRICE, status: "trialing")
    ends = 11.days.from_now.change(usec: 0)
    @stripe.subscription("sub_1")[:trial_end] = ends.to_i
    with_stripe { Billing::SubscriptionSync.new("sub_1", client: @stripe).call }

    with_stripe { get account_billing_path(@account) }
    assert_equal({ "eligible" => false, "days" => 14 }, inertia_shared_props.fetch("trial"))
    row = inertia_shared_props.fetch("residents").find { |resident| resident["id"] == @agent.to_param }
    assert_equal ends.iso8601, row.fetch("trial_ends_at")
    assert_not row.key?("has_payment_method"), "not synced; see the controller"
    others = inertia_shared_props.fetch("residents").reject { |resident| resident["id"] == @agent.to_param }
    assert others.all? { |resident| resident.key?("trial_ends_at") && resident["trial_ends_at"].nil? }

    @stripe.set_subscription_status("sub_1", "active")
    with_stripe { Billing::SubscriptionSync.new("sub_1", client: @stripe).call }
    @inertia_props = nil
    with_stripe { get account_billing_path(@account) }
    row = inertia_shared_props.fetch("residents").find { |resident| resident["id"] == @agent.to_param }
    assert_nil row.fetch("trial_ends_at"), "a converted trial has no end"
  end

  test "the Billing tab names no resident as holding the allowance: the account's residents share it" do
    @account.update!(billing_required: true)
    other = agents(:code_reviewer)
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    @stripe.put_subscription(id: "sub_1", agent: @agent, customer: "cus_1", price: CONVERSATION_PRICE, status: "active")
    @stripe.put_subscription(id: "sub_2", agent: other, customer: "cus_1", price: CONVERSATION_PRICE, status: "active")
    with_stripe do
      Billing::SubscriptionSync.new("sub_1", client: @stripe).call
      Billing::SubscriptionSync.new("sub_2", client: @stripe).call
      get account_billing_path(@account)
    end

    subscriptions = inertia_shared_props.fetch("residents").filter_map { |resident| resident.dig("entitlement", "subscription") }
    assert_equal 2, subscriptions.size
    assert subscriptions.none? { |subscription| subscription.key?("includes_allowance") }
  end

  test "an account that never had a subscription is offered the trial on the Billing tab" do
    @account.update!(billing_required: true)
    with_stripe { get account_billing_path(@account) }
    assert_equal({ "eligible" => true, "days" => 14 }, inertia_shared_props.fetch("trial"))
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
