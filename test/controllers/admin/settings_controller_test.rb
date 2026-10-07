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

  test "retired safeguard notice threshold cannot be changed through settings" do
    sign_in @admin
    original_threshold = Setting.instance.safeguard_owner_notice_threshold

    patch admin_settings_path, params: {
      setting: { site_name: "New Name", safeguard_owner_notice_threshold: original_threshold + 1 }
    }

    assert_redirected_to admin_settings_path
    assert_equal "New Name", Setting.instance.reload.site_name
    assert_equal original_threshold, Setting.instance.safeguard_owner_notice_threshold
  end

  test "admin switches follow-through on for residents and sees who they are" do
    agent = agents(:research_assistant)
    sign_in @admin
    patch admin_settings_path, params: { setting: { follow_through_residents: "#{agent.to_param}, nosuchid" } }

    assert_redirected_to admin_settings_path
    setting = Setting.instance.reload
    assert setting.follow_through_enabled_for?(agent)
    assert_not setting.follow_through_enabled_for?(agents(:code_reviewer))

    get admin_settings_path
    residents = inertia_shared_props["follow_through_residents"]
    assert_equal [ agent.to_param, "nosuchid" ], residents.map { |r| r["id"] }
    assert_equal agent.name, residents.first["name"]
    assert_nil residents.second["name"]
  end

  test "follow-through is off until an admin switches it on" do
    assert_not Setting.instance.follow_through_enabled_for?(agents(:research_assistant))
    Setting.instance.update!(follow_through_residents: "all")
    assert Setting.instance.follow_through_enabled_for?(agents(:research_assistant))
  end

end
