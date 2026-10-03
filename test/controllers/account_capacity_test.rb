require "test_helper"

class AccountCapacityControllerTest < ActionDispatch::IntegrationTest

  setup do
    Setting.instance.update!(max_accounts: Account.count, allow_signups: true)
  end

  test "signup page and direct signup post close at capacity" do
    get signup_path
    assert_redirected_to root_path
    assert_equal Account::ACCOUNT_LIMIT_MESSAGE, flash[:alert]
    assert_no_difference [ "User.count", "Account.count" ] do
      post signup_path, params: { email_address: "closed-signup@example.com" }
    end
    assert_redirected_to root_path
  end

  test "ordinary users cannot open account creation or post directly" do
    sign_in users(:user_1)
    get new_account_path
    assert_redirected_to root_path
    assert_no_difference "Account.count" do
      post accounts_path, params: { account: { name: "No room", account_type: "team" } }
    end
    assert_redirected_to root_path
    get edit_account_path(accounts(:personal_account))
    assert_redirected_to account_path(accounts(:personal_account))
    follow_redirect!
    assert_response :success
    assert_equal false, inertia_shared_props.dig("site_settings", "allow_account_creation")
  end

  test "site admins can create accounts and register a user at capacity" do
    sign_in users(:site_admin_user)
    get new_account_path
    assert_response :success
    assert_equal true, inertia_shared_props.dig("site_settings", "allow_account_creation")
    assert_difference "Account.count" do
      post accounts_path, params: { account: { name: "Admin capacity exception", account_type: "team" } }
    end
    assert_response :redirect
    get signup_path
    assert_response :success
    assert_difference [ "User.count", "Account.count" ] do
      post signup_path, params: { email_address: "admin-created-capacity@example.com" }
    end
    assert_redirected_to check_email_path
  end

  test "admin setting persists and invalid limits are rejected" do
    sign_in users(:site_admin_user)
    patch admin_settings_path, params: { setting: { max_accounts: 42 } }
    assert_equal 42, Setting.instance.reload.max_accounts
    patch admin_settings_path, params: { setting: { max_accounts: -1 } }
    assert_equal 42, Setting.instance.reload.max_accounts
  end

end
