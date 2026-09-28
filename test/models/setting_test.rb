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

end
