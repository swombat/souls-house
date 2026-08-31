require "test_helper"

class Admin::SettingsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @admin = users(:site_admin_user)
    @user = users(:user_1)
  end

  test "requires admin access" do
    sign_in @user
    get admin_settings_path
    assert_redirected_to root_path
  end

  test "admin can view settings" do
    sign_in @admin
    get admin_settings_path
    assert_response :success
  end

  test "admin can update settings" do
    sign_in @admin
    patch admin_settings_path, params: {
      setting: { site_name: "New Name", allow_signups: false, show_usage_in_chat: true }
    }

    assert_redirected_to admin_settings_path
    assert_equal "New Name", Setting.instance.reload.site_name
    assert_not Setting.instance.allow_signups
    assert Setting.instance.show_usage_in_chat
  end

end
