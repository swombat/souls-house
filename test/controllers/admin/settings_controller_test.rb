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

  test "admin picks the residents follow-through covers" do
    lume = agents(:research_assistant)
    other = agents(:code_reviewer)
    other.update_columns(follow_through: true)
    sign_in @admin

    patch admin_settings_path, params: {
      setting: { follow_through_scope: "selected", follow_through_resident_ids: [ "", lume.to_param ] }
    }

    assert_redirected_to admin_settings_path
    setting = Setting.instance.reload
    assert_equal "selected", setting.follow_through_scope
    assert setting.follow_through_enabled_for?(lume.reload)
    assert_not setting.follow_through_enabled_for?(other.reload), "a resident left out of the list is switched off"
    audit = AuditLog.where(action: "update_settings").last
    assert_equal [ lume.to_param ], audit.data["follow_through_on"]
    assert_equal [ other.to_param ], audit.data["follow_through_off"]

    get admin_settings_path
    listed = inertia_shared_props["follow_through_residents"].index_by { |r| r["id"] }
    assert listed[lume.to_param]["follow_through"]
    assert_equal lume.name, listed[lume.to_param]["name"]
    assert_not listed[other.to_param]["follow_through"]
  end

  test "saving other settings leaves the picked residents alone" do
    lume = agents(:research_assistant)
    lume.update_columns(follow_through: true)
    sign_in @admin

    patch admin_settings_path, params: { setting: { site_name: "Elsewhere" } }

    assert lume.reload.follow_through?
  end

  test "follow-through is off until an admin switches it on, and rejects unknown scopes" do
    setting = Setting.instance
    lume = agents(:research_assistant)
    lume.update_columns(follow_through: true)
    assert_equal "off", setting.follow_through_scope
    assert_not setting.follow_through_enabled_for?(lume)
    setting.update!(follow_through_scope: "all")
    assert setting.follow_through_enabled_for?(agents(:code_reviewer))
    assert_not setting.update(follow_through_scope: "most")
  end

end
