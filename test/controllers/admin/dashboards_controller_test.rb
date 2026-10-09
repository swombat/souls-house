require "test_helper"

class Admin::DashboardsControllerTest < ActionDispatch::IntegrationTest

  setup { Rails.cache.clear }

  test "only site administrators see the dashboard" do
    get admin_dashboard_path
    assert_redirected_to login_path
    sign_in(users(:regular_user))
    get admin_dashboard_path
    assert_redirected_to root_path
  end

  test "site administrator gets the dashboard page" do
    sign_in(users(:site_admin_user))
    get admin_dashboard_path
    assert_response :success
    assert_includes response.body, "admin/dashboard"
    assert_not_includes response.body, "api_key"
  end

  test "founding flag is site-admin only and audited" do
    account = accounts(:team_account)
    sign_in(users(:regular_user))
    patch founding_admin_account_path(account), params: { account: { founding: true } }
    assert_not account.reload.founding?

    sign_out if respond_to?(:sign_out)
    sign_in(users(:site_admin_user))
    assert_difference -> { AuditLog.count }, 1 do
      patch founding_admin_account_path(account), params: { account: { founding: true } }
    end
    assert account.reload.founding?
  end

end
