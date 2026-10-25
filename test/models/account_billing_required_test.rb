require "test_helper"

class AccountBillingRequiredTest < ActiveSupport::TestCase

  test "accounts created while billing is on need a plan for new residents; others don't" do
    before = Account.create!(name: "Before billing", account_type: :team)
    assert_not before.billing_required?

    Setting.instance.update!(billing_enabled: true)
    after = Account.create!(name: "After billing", account_type: :team)
    assert after.billing_required?
    assert_not before.reload.billing_required?, "the switch never changes an existing account"

    Setting.instance.update!(billing_enabled: false)
    assert after.reload.billing_required?, "turning the switch off changes no account either"
    assert_not Account.create!(name: "Later", account_type: :team).billing_required?
  end

  test "the setting remembers when billing was last switched on" do
    setting = Setting.instance
    assert_nil setting.billing_enabled_at
    freeze_time do
      setting.update!(billing_enabled: true)
      assert_equal Time.current, setting.billing_enabled_at
    end
    first = setting.billing_enabled_at
    travel 1.day do
      setting.update!(site_name: "Renamed")
      assert_equal first, setting.reload.billing_enabled_at
    end
  end

end
