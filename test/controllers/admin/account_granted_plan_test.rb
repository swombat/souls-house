require "test_helper"

# A site admin gives an account a plan from Site Admin (accounts.granted_plan),
# with nothing to pay.
class Admin::AccountGrantedPlanTest < ActionDispatch::IntegrationTest

  setup do
    @account = accounts(:team_account)
    @account.update_columns(granted_plan: nil)
  end

  test "only a site admin can give a plan" do
    sign_in(users(:regular_user))
    patch granted_plan_admin_account_path(@account), params: { account: { granted_plan: "colleagues" } }
    assert_nil @account.reload.granted_plan
    assert_not AuditLog.exists?(action: "admin_update_account_granted_plan")
  end

  test "each plan can be given, and the change is audited with the value before and after" do
    sign_in(users(:site_admin_user))
    before = nil
    Billing::AccountPlan::IDS.each do |id|
      assert_difference -> { AuditLog.where(action: "admin_update_account_granted_plan").count }, 1 do
        patch granted_plan_admin_account_path(@account), params: { account: { granted_plan: id } }
      end
      assert_redirected_to admin_accounts_path(account_id: @account)
      assert_equal id, @account.reload.granted_plan
      assert_equal id, @account.plan.id
      assert_equal "grant", @account.plan_source
      data = AuditLog.where(action: "admin_update_account_granted_plan").order(:id).last.data
      assert_equal [ before, id, id ], data.values_at("granted_plan_before", "granted_plan", "plan_now")
      before = id
    end
  end

  test "blank removes the grant" do
    @account.update!(granted_plan: "partners")
    sign_in(users(:site_admin_user))
    patch granted_plan_admin_account_path(@account), params: { account: { granted_plan: "" } }
    assert_nil @account.reload.granted_plan
    assert_equal "companions", @account.plan.id
    data = AuditLog.where(action: "admin_update_account_granted_plan").order(:id).last.data
    assert_equal [ "partners", nil ], data.values_at("granted_plan_before", "granted_plan")
  end

  test "an unknown plan is refused, not saved as none" do
    @account.update!(granted_plan: "partners")
    sign_in(users(:site_admin_user))
    patch granted_plan_admin_account_path(@account), params: { account: { granted_plan: "enterprise" } }
    assert_response :bad_request
    assert_equal "partners", @account.reload.granted_plan
    assert_not AuditLog.exists?(action: "admin_update_account_granted_plan")
  end

  test "a paid plan line stays on the bill and wins while it is at least the grant" do
    AccountSubscription.create!(account: @account, stripe_subscription_id: "sub_grant_test", plan: "partners",
      stripe_status: "active")
    sign_in(users(:site_admin_user))

    patch granted_plan_admin_account_path(@account), params: { account: { granted_plan: "companions" } }
    assert_equal "subscription", @account.reload.plan_source
    assert_equal "partners", @account.plan.id

    patch granted_plan_admin_account_path(@account), params: { account: { granted_plan: "colleagues" } }
    assert_equal "grant", @account.reload.plan_source
    assert_equal "colleagues", @account.plan.id
    assert @account.live_plan_subscription, "the paid line is untouched"
  end

  test "the selected account says why its plan is what it is" do
    AccountSubscription.create!(account: @account, stripe_subscription_id: "sub_grant_json", plan: "partners",
      stripe_status: "active")
    code = BillingCode.create!(code: "PARTNERS-FREE", effect: "plan:partners", created_by: users(:site_admin_user))
    BillingCodeRedemption.create!(account: @account, billing_code: code, effect: code.effect,
      redeemed_by: users(:site_admin_user), redeemed_at: Time.current)
    @account.update!(granted_plan: "colleagues")
    sign_in(users(:site_admin_user))

    get admin_accounts_path, params: { account_id: @account.to_param }
    plan = inertia_shared_props.fetch("selected_account").fetch("plan")
    assert_equal "colleagues", plan.fetch("id")
    assert_equal "grant", plan.fetch("source")
    assert_equal "colleagues", plan.fetch("granted_plan")
    assert_equal "partners", plan.fetch("subscription").fetch("plan")
    assert_equal true, plan.fetch("subscription").fetch("in_force")
    assert_equal [ { "code" => "PARTNERS-FREE", "plan" => "partners", "plan_name" => "Partners" } ], plan.fetch("plan_codes")
    assert_equal Billing::AccountPlan::IDS, plan.fetch("plans").map { |entry| entry.fetch("id") }
  end

  test "a Companions grant means a first bill carries no plan line" do
    @account.update!(granted_plan: "companions")
    sign_in(users(:site_admin_user))
    get admin_accounts_path, params: { account_id: @account.to_param }
    plan = inertia_shared_props.fetch("selected_account").fetch("plan")
    assert_nil plan.fetch("subscription")
    assert_nil plan.fetch("plan_to_pay_for")
  end

end
