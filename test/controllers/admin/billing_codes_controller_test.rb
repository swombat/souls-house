require "test_helper"

class Admin::BillingCodesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @admin = users(:site_admin_user)
    @user = users(:user_1)
  end

  test "requires admin access" do
    sign_in @user
    get admin_billing_codes_path
    assert_redirected_to root_path
    post admin_billing_codes_path, params: { billing_code: { effect: "at_cost" } }
    assert_redirected_to root_path
    assert_equal 0, BillingCode.count
  end

  test "an admin makes a code, with one made up when none is given, and sees it listed" do
    sign_in @admin
    post admin_billing_codes_path, params: { billing_code: { code: "pepe-2026", effect: "at_cost", max_redemptions: 2, note: "Pepe" } }
    assert_redirected_to admin_billing_codes_path
    code = BillingCode.find_by!(code: "PEPE-2026")
    assert_equal 2, code.max_redemptions
    assert_equal @admin, code.created_by

    post admin_billing_codes_path, params: { billing_code: { code: "", effect: "at_cost" } }
    assert_redirected_to admin_billing_codes_path
    assert_equal 2, BillingCode.count
    assert_match BillingCode::FORMAT, BillingCode.where.not(code: "PEPE-2026").sole.code

    get admin_billing_codes_path
    assert_response :success
    assert_equal "admin/billing-codes", inertia_component
    assert_equal 2, inertia_shared_props["codes"].size
    assert_equal [ "at_cost" ], inertia_shared_props["effects"]
  end

  test "an invalid code comes back with errors and nothing made" do
    sign_in @admin
    post admin_billing_codes_path, params: { billing_code: { code: "no spaces", effect: "at_cost" } }
    assert_redirected_to admin_billing_codes_path
    assert_equal 0, BillingCode.count
  end

  test "withdrawing a code and withdrawing a redemption are separate acts with separate effects" do
    sign_in @admin
    code = BillingCode.create!(code: "PEPE", effect: "at_cost", created_by: @admin)
    account = accounts(:personal_account)
    redemption = BillingCode.redeem!(code: "PEPE", account: account, by: @user)

    patch revoke_admin_billing_code_path(code)
    assert_redirected_to admin_billing_codes_path
    assert code.reload.revoked?
    assert account.reload.eligible_for?("at_cost")

    patch admin_withdraw_billing_code_redemption_path(redemption)
    assert_redirected_to admin_billing_codes_path
    assert_not redemption.reload.live?
    assert_equal @admin, redemption.withdrawn_by
    assert_not account.reload.eligible_for?("at_cost")
    assert AuditLog.exists?(action: "withdraw_billing_code_redemption")
  end

end
