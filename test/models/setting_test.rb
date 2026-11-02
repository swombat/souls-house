require "test_helper"

class SettingTest < ActiveSupport::TestCase

  test "new settings default to souls.house" do
    assert_equal "souls.house", Setting.new.site_name
    assert_equal "souls.house", Setting.columns_hash.fetch("site_name").default
  end

  test "instance preserves a configured site name" do
    Setting.instance.update!(site_name: "My House")

    assert_equal "My House", Setting.instance.site_name
  end

  test "instance returns setting" do
    setting = Setting.instance
    assert_equal setting, Setting.instance
  end

  test "validates site_name presence" do
    setting = Setting.instance
    setting.site_name = ""
    assert_not setting.valid?
  end

  test "validates site_name length" do
    setting = Setting.instance
    setting.site_name = "a" * 101
    assert_not setting.valid?
  end

  test "voice mode scope defaults to the account's choice and has three states" do
    assert_equal "account_choice", Setting.columns_hash.fetch("voice_mode_scope").default

    setting = Setting.instance
    setting.voice_mode_scope = "selected"
    assert_not setting.valid?
    %w[disabled account_choice enabled].each do |scope|
      setting.voice_mode_scope = scope
      assert setting.valid?, scope
    end
  end

  test "voice mode follows the site scope, then the account switch" do
    account = accounts(:team_account)
    setting = Setting.instance

    setting.update!(voice_mode_scope: "disabled")
    account.update!(voice_mode_enabled: true)
    assert_not setting.voice_mode_enabled_for?(account)

    setting.update!(voice_mode_scope: "account_choice")
    assert setting.voice_mode_enabled_for?(account)
    account.update!(voice_mode_enabled: false)
    assert_not setting.voice_mode_enabled_for?(account)

    setting.update!(voice_mode_scope: "enabled")
    assert setting.voice_mode_enabled_for?(account)
    assert_not setting.voice_mode_enabled_for?(nil)
  end

end
