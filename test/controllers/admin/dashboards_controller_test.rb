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

  test "changing an account's founding flag refreshes a warm dashboard" do
    # The test environment uses a null cache; this needs a real one.
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) { founding_change_refreshes_cache }
  end

  def founding_change_refreshes_cache
    account = accounts(:team_account)
    account.update!(founding: true)
    sign_in(users(:site_admin_user))
    get admin_dashboard_path
    assert Rails.cache.exist?(SiteDashboard::CACHE_KEY)

    patch founding_admin_account_path(account), params: { account: { founding: false } }
    assert_not Rails.cache.exist?(SiteDashboard::CACHE_KEY)
    get admin_dashboard_path
    founding = Rails.cache.read(SiteDashboard::CACHE_KEY)[:founding].map { |row| row[:id] }
    assert_not_includes founding, account.to_param
  end

  test "a payload cached by the earlier dashboard is not served to the new page" do
    store = ActiveSupport::Cache::MemoryStore.new
    store.write("admin/site_dashboard/v1", { headline: {}, generated_at: Time.current.iso8601 })
    Rails.stub(:cache, store) do
      sign_in(users(:site_admin_user))
      get admin_dashboard_path
      assert_response :success
      payload = store.read(SiteDashboard::CACHE_KEY)
      assert payload.key?(:server)
      assert payload.key?(:storage)
    end
  end

end
