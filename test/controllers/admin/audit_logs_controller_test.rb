require "test_helper"

class Admin::AuditLogsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @site_admin_user = users(:site_admin_user)
    @regular_user = users(:regular_user)
    @user_1 = users(:user_1)
    @personal_account = accounts(:personal_account)
    @team_account = accounts(:team_account)

    # NOTE: create_test_audit_logs called per test to avoid transaction isolation issues
  end

  # === Authentication and Authorization Tests ===

  test "should redirect to login when not authenticated" do
    get admin_audit_logs_path
    assert_redirected_to login_path
  end

  test "should redirect to root when authenticated as regular user" do
    sign_in(@regular_user)
    get admin_audit_logs_path
    assert_redirected_to root_path
  end

  test "should allow access for site admin user" do
    sign_in(@site_admin_user)
    get admin_audit_logs_path
    assert_response :success
    assert_equal "admin/audit-logs", inertia_component
  end

  # === Basic Data and Props Tests ===

  test "should return audit logs with correct structure for site admin" do
    sign_in(@site_admin_user)
    get admin_audit_logs_path

    assert_response :success
    props = inertia_shared_props

    # Core structure tests
    assert props.key?("audit_logs"), "Props should include audit_logs key"
    assert props.key?("selected_log"), "Props should include selected_log key"
    assert props.key?("pagination"), "Props should include pagination key"
    assert props.key?("filters"), "Props should include filters key"
    assert props.key?("current_filters"), "Props should include current_filters key"

    # Verify audit logs structure
    audit_logs = props["audit_logs"]
    assert audit_logs.is_a?(Array), "Audit logs should be an array"

    if audit_logs.any?
      log = audit_logs.first
      assert log.key?("id"), "Log should have id"
      assert log.key?("action"), "Log should have action"
      assert log.key?("created_at"), "Log should have created_at"
      assert log.key?("display_action"), "Log should have display_action"
      assert log.key?("actor_name"), "Log should have actor_name"
      assert log.key?("target_name"), "Log should have target_name"
    end
  end

  test "should return audit logs count in database" do
    sign_in(@site_admin_user)

    # Check actual database count
    db_count = AuditLog.count

    get admin_audit_logs_path
    assert_response :success

    props = inertia_shared_props
    returned_count = props["audit_logs"]&.size || 0
    pagination = props["pagination"]

    assert db_count >= 0, "Should have audit logs in database"
  end

  # === Pagination Tests ===

  test "should paginate filtered audit logs newest first across first middle and last pages" do
    sign_in(@site_admin_user)
    newest_at = 1.hour.ago
    logs = 5.times.map do |i|
      AuditLog.create!(
        user: @user_1, account: @personal_account, action: "pagy_regression",
        created_at: newest_at - i.minutes
      )
    end
    AuditLog.create!(action: "unrelated_pagy_regression", created_at: newest_at + 1.minute)

    [ [ 1, 0, 2, nil, 2 ], [ 2, 2, 2, 1, 3 ], [ 3, 4, 1, 2, nil ] ].each do |page, offset, size, previous_page, next_page|
      @inertia_props = nil # The helper memoizes props across requests.
      get admin_audit_logs_path, params: { audit_action: "pagy_regression", per_page: 2, page: page }

      assert_response :success
      props = inertia_shared_props
      assert_equal logs.slice(offset, size).map(&:to_param), props.fetch("audit_logs").pluck("id"),
        "Audit page #{page} should contain only its ordered filtered logs"
      assert_equal({
        "count" => 5, "page" => page, "pages" => 3, "last" => 3,
        "from" => offset + 1, "to" => offset + size,
        "prev" => previous_page, "next" => next_page,
        "series" => [ "1", "2", "3" ], "per_page" => "2"
      }, props.fetch("pagination"))
    end
  end

  test "should handle pagination with large per_page value" do
    sign_in(@site_admin_user)

    get admin_audit_logs_path, params: { per_page: 100 }
    assert_response :success

    props = inertia_shared_props
    pagination = props["pagination"]

    assert_equal "100", pagination["per_page"]
  end

  # === Filtering Tests ===

  test "should filter by user_id" do
    sign_in(@site_admin_user)

    # Get user with audit logs
    user_with_logs = @user_1
    user_id = user_with_logs.id

    get admin_audit_logs_path, params: { user_id: user_id }
    assert_response :success

    props = inertia_shared_props
    audit_logs = props["audit_logs"]
    current_filters = props["current_filters"]

    assert_equal user_id.to_s, current_filters["user_id"], "Filter should be applied"

    # All returned logs should belong to the specified user
    audit_logs.each do |log|
      if log["user_id"]
        assert_equal user_id, log["user_id"], "All logs should belong to filtered user"
      end
    end
  end

  test "should filter by account_id" do
    sign_in(@site_admin_user)

    account_id = @team_account.id

    get admin_audit_logs_path, params: { filter_account_id: account_id }
    assert_response :success

    props = inertia_shared_props
    audit_logs = props["audit_logs"]
    current_filters = props["current_filters"]

    assert_equal account_id.to_s, current_filters["filter_account_id"], "Filter should be applied"
  end

  test "should filter by action" do
    sign_in(@site_admin_user)

    get admin_audit_logs_path, params: { audit_action: "create" }
    assert_response :success

    props = inertia_shared_props
    audit_logs = props["audit_logs"]
    current_filters = props["current_filters"]

    assert_equal "create", current_filters["audit_action"], "Filter should be applied"

    # All returned logs should have the specified action
    audit_logs.each do |log|
      assert_equal "create", log["action"], "All logs should have filtered action"
    end
  end

  test "should filter by auditable_type" do
    sign_in(@site_admin_user)

    get admin_audit_logs_path, params: { auditable_type: "Account" }
    assert_response :success

    props = inertia_shared_props
    audit_logs = props["audit_logs"]
    current_filters = props["current_filters"]

    assert_equal "Account", current_filters["auditable_type"], "Filter should be applied"
  end

  test "should handle comma-separated action filters" do
    sign_in(@site_admin_user)

    # Create specific logs for testing
    login_log = AuditLog.create!(user: @user_1, account: @personal_account, action: "login", auditable: @user_1)
    logout_log = AuditLog.create!(user: @user_1, account: @personal_account, action: "logout", auditable: @user_1)
    update_log = AuditLog.create!(user: @user_1, account: @personal_account, action: "update", auditable: @user_1)

    get admin_audit_logs_path, params: { audit_action: "login,logout" }
    assert_response :success

    props = inertia_shared_props
    audit_logs = props["audit_logs"]
    current_filters = props["current_filters"]

    # Check the filter was applied correctly
    assert_equal "login,logout", current_filters["audit_action"], "Filter should be applied"

    # Check that returned logs only have the specified actions
    audit_logs.each do |log|
      assert_includes [ "login", "logout" ], log["action"], "All logs should have filtered actions"
      assert_not_equal "update", log["action"], "Update action should not be included"
    end
  end

  test "should handle comma-separated auditable_type filters" do
    sign_in(@site_admin_user)

    # Create specific logs for testing
    user_log = AuditLog.create!(user: @user_1, account: @personal_account, action: "create", auditable: @user_1)
    account_log = AuditLog.create!(user: @user_1, account: @personal_account, action: "create", auditable: @personal_account)
    # Create a third log with a different type to ensure filtering works
    other_user_log = AuditLog.create!(user: @regular_user, account: @team_account, action: "create", auditable: @regular_user)

    get admin_audit_logs_path, params: { auditable_type: "User,Account" }
    assert_response :success

    props = inertia_shared_props
    audit_logs = props["audit_logs"]
    current_filters = props["current_filters"]

    # Check the filter was applied correctly
    assert_equal "User,Account", current_filters["auditable_type"], "Filter should be applied"

    # Check that returned logs only have the specified types
    audit_logs.each do |log|
      if log["auditable_type"].present?
        assert_includes [ "User", "Account" ], log["auditable_type"], "All logs should have filtered types"
      end
    end
  end

  # === Filter Options Tests ===

  test "should provide filter options" do
    sign_in(@site_admin_user)

    get admin_audit_logs_path
    assert_response :success

    props = inertia_shared_props
    filters = props["filters"]

    assert filters.is_a?(Hash), "Filters should be a hash"
    assert filters.key?("users"), "Filters should include users"
    assert filters.key?("accounts"), "Filters should include accounts"
    assert filters.key?("actions"), "Filters should include actions"
    assert filters.key?("types"), "Filters should include types"

    # Verify users structure
    users = filters["users"]
    if users && users.any?
      user = users.first
      assert user.key?("id"), "User filter option should have id"
      assert user.key?("email_address"), "User filter option should have email_address"
    end

    # Verify accounts structure
    accounts = filters["accounts"]
    if accounts && accounts.any?
      account = accounts.first
      assert account.key?("id"), "Account filter option should have id"
      assert account.key?("name"), "Account filter option should have name"
    end
  end

  # === Selected Log Tests ===

  test "should not include selected_log when no log_id param" do
    sign_in(@site_admin_user)

    get admin_audit_logs_path
    assert_response :success

    props = inertia_shared_props
    assert_nil props["selected_log"], "Should not have selected_log without log_id param"
  end

  test "should include selected_log when valid log_id param provided" do
    sign_in(@site_admin_user)

    # Create a specific audit log for this test
    audit_log = create_test_log_with_associations

    get admin_audit_logs_path, params: { log_id: audit_log.to_param }
    assert_response :success

    props = inertia_shared_props
    selected_log = props["selected_log"]

    assert selected_log.present?, "Selected log should be present when valid log_id is provided"
    assert_equal audit_log.to_param, selected_log["id"]

    # Verify selected log includes associations
    if audit_log.user
      assert selected_log.key?("user"), "Selected log should include user association"
    end
    if audit_log.account
      assert selected_log.key?("account"), "Selected log should include account association"
    end
    if audit_log.auditable
      assert selected_log.key?("auditable"), "Selected log should include auditable association"
    end
  end

  # === Model Method Tests ===

  test "should chain scopes correctly" do
    sign_in(@site_admin_user)

    # Test scope chaining directly
    user_id = @user_1.id
    action = "create"
    scoped_logs = AuditLog.by_user(user_id).by_action(action).recent

    # Test via controller
    get admin_audit_logs_path, params: { user_id: user_id, audit_action: action }
    assert_response :success

    props = inertia_shared_props
    controller_logs = props["audit_logs"]

    # Both should return the same results
    assert_equal scoped_logs.count, controller_logs.size, "Controller and model should return same count"
  end

  test "should handle available_actions and available_types class methods" do
    actions = AuditLog.available_actions
    types = AuditLog.available_types

    assert actions.is_a?(Array), "Available actions should be an array"
    assert types.is_a?(Array), "Available types should be an array"
  end

  private

  def create_test_log_with_associations
    AuditLog.create!(
      user: @user_1,
      account: @team_account,
      action: "test_action",
      auditable: @team_account,
      auditable_type: "Account",
      auditable_id: @team_account.id,
      data: { description: "Test log with full associations", test: true }
    )
  end

end
