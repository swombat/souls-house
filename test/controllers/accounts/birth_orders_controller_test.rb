require "test_helper"
require "support/fake_stripe"

# The creation wizard's Plan step, end to end through the controllers: the
# page offers it only in an account that pays, the card form saves a card,
# the order opens the first payment, and confirming bears the resident once
# Stripe says it is paid.
class Accounts::BirthOrdersControllerTest < ActionDispatch::IntegrationTest

  include FakeStripe::Helpers

  setup do
    Setting.instance.update!(allow_agents: true)
    @account = accounts(:personal_account)
    @account.update!(billing_required: true)
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    sign_in(users(:user_1))
  end

  def draft = { name: "Aria", system_prompt: "Be curious.", model_id: "openrouter/auto", open_beginning: false }

  test "the wizard offers the Plan step only in an account that pays" do
    @stripe.put_payment_method("pm_visa")
    @stripe.put_customer("cus_1", default_payment_method: "pm_visa")

    Billing.stub(:client, @stripe) { get new_account_agent_path(@account) }
    billing = inertia_shared_props.fetch("billing")
    assert_nil inertia_shared_props.fetch("vm_birth_refusal")
    assert billing.fetch("can_pay")
    assert_equal({ "brand" => "visa", "last4" => "4242", "exp_month" => 10, "exp_year" => 2030 }, billing.fetch("payment_method"))
    assert_equal %w[conversation life work], billing.fetch("tiers").map { |tier| tier["id"] }
    assert_equal %w[companions partners colleagues], billing.fetch("account_plans").map { |plan| plan["id"] }
    # The Plan step names the account's plan.
    assert_equal({ "id" => "companions", "source" => "default", "subscription" => nil }, billing.fetch("account_plan"))
    refute billing.key?("trial"), "the trial is one top-level prop, as on the Billing tab"
    assert_equal account_birth_orders_path(@account), billing.fetch("birth_orders_url")
    assert_equal false, billing.fetch("adds_to_bill"), "no live subscription: the card path"

    @account.update!(billing_required: false)
    get new_account_agent_path(@account)
    @inertia_props = nil
    assert_nil inertia_shared_props.fetch("billing")
  end

  test "the free trial: offered on the Plan step, no card, Stripe Checkout, and Stripe's return bears the resident" do
    Billing.stub(:client, @stripe) { get new_account_agent_path(@account) }
    assert_equal({ "eligible" => true, "days" => 14 }, inertia_shared_props.fetch("trial"))

    Billing.stub(:client, @stripe) do
      assert_no_difference "Agent.count" do
        post account_birth_orders_path(@account), params: { agent: draft, tier: "conversation", trial: true }, as: :json
      end
      assert_response :created
      body = response.parsed_body
      assert_equal "https://checkout.stripe.com/c/pay/cs_test_1", body.fetch("checkout_url")
      assert_nil body.fetch("client_secret")
      assert body.dig("order", "trial")
      order = ResidentBirthOrder.sole
      params, = @stripe.checkout_sessions.sole
      assert_equal trial_return_account_birth_order_url(@account, order), params[:success_url]
      assert_equal new_account_agent_url(@account), params[:cancel_url]
      assert AuditLog.exists?(action: "start_trial_birth")

      post body.fetch("payment_url"), as: :json
      assert_equal "https://checkout.stripe.com/c/pay/cs_test_1", response.parsed_body.fetch("checkout_url")

      get trial_return_account_birth_order_path(@account, order)
      assert_redirected_to new_account_agent_path(@account), "not complete yet: Stripe is still confirming"

      @stripe.complete_checkout_session("cs_test_1", subscription_id: "sub_trial")
      assert_difference "Agent.count", 1 do
        get trial_return_account_birth_order_path(@account, order)
      end
      agent = @account.agents.find_by!(name: "Aria")
      assert_redirected_to onboarding_account_agent_path(@account, agent)
    end

    @inertia_props = nil
    Billing.stub(:client, @stripe) { get new_account_agent_path(@account) }
    assert_equal({ "eligible" => false, "days" => 14 }, inertia_shared_props.fetch("trial"))
  end

  test "the free trial is for a small resident at the standard rate, once" do
    Billing.stub(:client, @stripe) do
      post account_birth_orders_path(@account), params: { agent: draft, tier: "life", trial: true }, as: :json
      assert_response :unprocessable_entity
      assert_match "small resident", response.parsed_body.fetch("error")

      @account.update!(trial_started_at: 1.day.ago)
      post account_birth_orders_path(@account), params: { agent: draft, tier: "conversation", trial: true }, as: :json
      assert_response :unprocessable_entity
      assert_match "already had its free trial", response.parsed_body.fetch("error")
    end
    assert_empty @stripe.checkout_sessions
  end

  test "saving a card from the wizard" do
    Billing.stub(:client, @stripe) do
      post account_billing_card_path(@account), as: :json
      assert_response :success
      session_id = response.parsed_body.fetch("session_id")
      assert_equal "#{session_id}_secret", response.parsed_body.fetch("client_secret")

      @stripe.complete_setup_session(session_id, payment_method: "pm_new")
      post complete_account_billing_card_path(@account), params: { session_id: session_id }, as: :json
      assert_response :success
      assert_equal "4242", response.parsed_body.dig("payment_method", "last4")
    end
  end

  test "paying for a resident: the order opens a payment, and confirming bears it once paid" do
    @stripe.put_payment_method("pm_visa")
    @stripe.put_customer("cus_1", default_payment_method: "pm_visa")

    Billing.stub(:client, @stripe) do
      assert_no_difference "Agent.count" do
        post account_birth_orders_path(@account), params: { agent: draft, tier: "life" }, as: :json
      end
      assert_response :created
      body = response.parsed_body
      assert_equal "pi_sub_new_1_secret", body.fetch("client_secret")
      assert_equal "pm_visa", body.fetch("payment_method_id")
      confirm_url = body.fetch("confirm_url")

      post confirm_url, as: :json
      assert_response :success
      assert_equal "pending", response.parsed_body.dig("order", "state")
      assert_nil response.parsed_body.fetch("redirect_to")

      @stripe.set_subscription_status("sub_new_1", "active")
      assert_difference "Agent.count", 1 do
        post confirm_url, as: :json
      end
      agent = @account.agents.find_by!(name: "Aria")
      assert_equal onboarding_account_agent_path(@account, agent), response.parsed_body.fetch("redirect_to")
      assert_equal "life", ResidentEntitlement.find_by!(agent: agent).tier
    end
  end

  test "an uncertain Stripe answer returns the order to resume, and resuming pays the same subscription" do
    @stripe.put_payment_method("pm_visa")
    @stripe.put_customer("cus_1", default_payment_method: "pm_visa")
    @stripe.fail_next_subscription_create(created: true)

    Billing.stub(:client, @stripe) do
      post account_birth_orders_path(@account), params: { agent: draft, tier: "conversation" }, as: :json
      assert_response :service_unavailable
      body = response.parsed_body
      assert_equal "pending", body.dig("order", "state")
      payment_url = body.fetch("payment_url")

      post payment_url, as: :json
      assert_response :success
      assert_equal "pi_sub_new_1_secret", response.parsed_body.fetch("client_secret")

      @stripe.set_subscription_status("sub_new_1", "active")
      post payment_url, as: :json
      assert_response :success
      assert response.parsed_body.fetch("paid")
      assert_nil response.parsed_body["client_secret"]
    end
    assert_equal 1, @stripe.created_subscriptions.size
    assert ResidentBirthOrder.sole.born?
  end

  test "only the owner can pay, and the reasons come back as JSON" do
    Billing.stub(:client, @stripe) do
      post account_birth_orders_path(@account), params: { agent: draft, tier: "conversation" }, as: :json
      assert_response :unprocessable_entity
      assert_equal "Add a card to pay for the plan first.", response.parsed_body.fetch("error")
    end

    sign_in(users(:regular_user))
    post account_birth_orders_path(@account), params: { agent: draft, tier: "conversation" }, as: :json
    assert_not response.successful?
    assert_equal 0, ResidentBirthOrder.count
  end

  test "someone else's order can't be confirmed" do
    order = ResidentBirthOrder.create!(account: @account, creator: users(:site_admin_user), tier: "conversation",
      stripe_subscription_id: "sub_x", birth_attributes: { name: "Theirs" })
    post confirm_account_birth_order_path(@account, order), as: :json
    assert_response :not_found
  end

  test "with a live account subscription: the quote, a moved quote refused with the new one, then the resident on the account's bill" do
    @stripe.put_payment_method("pm_visa")
    @stripe.put_customer("cus_1", default_payment_method: "pm_visa")
    first = agents(:research_assistant)
    @stripe.put_shared_subscription(id: "sub_acct", account: @account, customer: "cus_1", status: "active",
      items: [ { agent: first, price: LIFE_PRICE, id: "si_first" } ])
    Billing::SubscriptionSync.new("sub_acct", client: @stripe).call

    Billing.stub(:client, @stripe) { get new_account_agent_path(@account) }
    assert inertia_shared_props.fetch("billing").fetch("adds_to_bill"), "the Plan step shows no card terms"

    Billing.stub(:client, @stripe) do
      assert_no_difference "Agent.count" do
        post account_birth_orders_path(@account), params: { agent: draft, tier: "conversation" }, as: :json
      end
      assert_response :created
      body = response.parsed_body
      assert_nil body.fetch("client_secret")
      assert_equal "item", body.dig("order", "kind")
      quote = body.fetch("item_quote")
      assert_equal %w[added_cents currency digest next_at next_total_cents recurring_cents], quote.keys.sort
      order = ResidentBirthOrder.sole
      assert_equal confirm_item_account_birth_order_path(@account, order), body.fetch("confirm_item_url")
      assert_empty @stripe.subscription_updates

      post body.fetch("confirm_item_url"), params: { digest: "0" * 64 }, as: :json
      assert_response :conflict
      fresh = response.parsed_body.fetch("item_quote")
      assert_empty @stripe.subscription_updates, "a moved quote sends nothing"

      assert_difference "Agent.count", 1 do
        post body.fetch("confirm_item_url"), params: { digest: fresh.fetch("digest") }, as: :json
      end
      assert_response :success
      assert response.parsed_body.fetch("accepted")
      assert_not response.parsed_body.key?("item_quote")

      post body.fetch("confirm_url"), as: :json
      assert_equal onboarding_account_agent_path(@account, order.reload.agent), response.parsed_body.fetch("redirect_to")
    end
  end

end
