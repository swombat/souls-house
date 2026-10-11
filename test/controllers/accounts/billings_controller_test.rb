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

  test "shows each hosted resident's plan and the catalogue" do
    ResidentEntitlement.create!(agent: @agent, account: @account, source: "complimentary",
      state: "complimentary", complimentary_granted_at: Time.current)

    get account_billing_path(@account)

    assert_response :success
    assert_equal "accounts/billing", inertia_component
    props = inertia_shared_props
    assert props.dig("billing", "configured")
    assert props.dig("billing", "can_pay")
    assert_equal %w[starter studio], props["tiers"].map { |tier| tier["id"] }
    resident = props["residents"].find { |row| row["id"] == @agent.to_param }
    assert_equal "complimentary", resident.dig("entitlement", "state")
  end

  test "checkout sends the owner to Stripe with tax, VAT ID collection and the resident in metadata" do
    Billing.stub(:client, @stripe) do
      post checkout_account_billing_path(@account), params: { agent_id: @agent.to_param, tier: "starter" },
        headers: { "X-Inertia" => "true" }
    end

    assert_response :conflict
    assert_equal "https://checkout.stripe.com/c/pay/cs_test_1", response.headers["X-Inertia-Location"]
    params, opts = @stripe.checkout_sessions.sole
    assert_equal "subscription", params[:mode]
    assert_equal [ { price: FakeStripe::Helpers::STARTER_PRICE, quantity: 1 } ], params[:line_items]
    assert_equal @agent.id.to_s, params.dig(:subscription_data, :metadata, :agent_id)
    assert params.dig(:automatic_tax, :enabled)
    assert params.dig(:tax_id_collection, :enabled)
    assert_match(/\Asouls-house-checkout-#{@agent.id}-starter-/, opts[:idempotency_key])
    assert_equal "cus_test_1", BillingCustomer.find_by!(account: @account).stripe_customer_id
    assert ResidentEntitlement.find_by!(agent: @agent).pending?
  end

  test "checkout refuses a resident that already has a live subscription" do
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    ResidentSubscription.create!(agent: @agent, account: @account, stripe_subscription_id: "sub_1",
      tier: "starter", stripe_status: "active")

    Billing.stub(:client, @stripe) do
      post checkout_account_billing_path(@account), params: { agent_id: @agent.to_param, tier: "studio" }
    end

    assert_redirected_to account_billing_path(@account)
    assert_match(/already has a subscription/, flash[:alert])
    assert_empty @stripe.checkout_sessions
  end

  test "the portal opens for the account's Stripe customer" do
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")

    Billing.stub(:client, @stripe) do
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

end
