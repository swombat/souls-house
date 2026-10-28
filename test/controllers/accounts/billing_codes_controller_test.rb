require "test_helper"
require "support/fake_stripe"

class Accounts::BillingCodesControllerTest < ActionDispatch::IntegrationTest

  include FakeStripe::Helpers

  setup do
    @owner = users(:user_1)
    @account = accounts(:personal_account)
    @code = BillingCode.create!(code: "PEPE-AT-COST", effect: "at_cost", created_by: users(:site_admin_user))
    Setting.instance.update!(allow_agents: true)
  end

  test "the owner redeems a code and is offered the at-cost plans from then on" do
    sign_in(@owner)
    get account_billing_path(@account)
    assert_equal %w[conversation life work], inertia_shared_props["offers"].map { |offer| offer["id"] }
    assert_equal %w[standard], inertia_shared_props.dig("codes", "eligible_rates")

    post account_billing_codes_path(@account), params: { code: "pepe-at-cost" }

    assert_redirected_to account_billing_path(@account)
    assert_match(/Code accepted/, flash[:notice])
    redemption = @account.billing_code_redemptions.sole
    assert_equal "at_cost", redemption.effect
    assert_equal @owner, redemption.redeemed_by
    assert AuditLog.exists?(action: "redeem_billing_code", user: @owner)

    get account_billing_path(@account)
    assert_equal %w[standard at_cost], inertia_shared_props.dig("codes", "eligible_rates")
    offers = inertia_shared_props["offers"]
    assert_equal %w[conversation conversation_at_cost life life_at_cost work work_at_cost], offers.map { |offer| offer["id"] }
    at_cost = offers.find { |offer| offer["id"] == "conversation_at_cost" }
    assert_equal 8, at_cost["monthly_usd"]
    assert_equal 0, at_cost.dig("features", "allowance_usd")
    assert_equal "PEPE-AT-COST", inertia_shared_props.dig("codes", "redemptions", 0, "code")
  end

  test "a refused code says why, and a non-owner can't redeem" do
    sign_in(@owner)
    post account_billing_codes_path(@account), params: { code: "NOPE" }
    assert_redirected_to account_billing_path(@account)
    assert_match(/isn't one this house knows/, flash[:alert])
    assert_equal 0, BillingCodeRedemption.count

    sign_in(users(:regular_user))
    post account_billing_codes_path(@account), params: { code: "PEPE-AT-COST" }
    assert_no_match(/Code accepted/, flash[:notice].to_s)
    assert_equal 0, BillingCodeRedemption.count
  end

  test "checkout at a rate the account holds no grant for is refused" do
    sign_in(@owner)
    agent = agents(:research_assistant)
    @stripe = FakeStripe.new
    Billing.stub(:client, @stripe) do
      post checkout_account_billing_path(@account), params: { agent_id: agent.to_param, tier: "conversation", rate: "at_cost" },
        headers: { "X-Inertia" => "true" }
    end
    assert_redirected_to account_billing_path(@account)
    assert_match(/can't buy plans at that rate/, flash[:alert])
  end

end
