require "test_helper"

class AccountCapacityTest < ActiveSupport::TestCase

  setup do
    Current.reset
    @setting = Setting.instance
  end

  test "default limit is thirty and only nonnegative integers are accepted" do
    assert_equal 30, Setting.new.max_accounts
    [ -1, 1.5, nil, "invalid" ].each do |value|
      @setting.max_accounts = value
      assert_not @setting.valid?, value.inspect
    end
    @setting.max_accounts = 0
    assert @setting.valid?
  end

  test "last place is allowed then account creation stops" do
    @setting.update!(max_accounts: Account.count + 1)
    Account.create!(name: "Last place", account_type: :team)
    record = Account.new(name: "Over capacity", account_type: :team)
    assert_not record.save
    assert_includes record.errors[:base], Account::ACCOUNT_LIMIT_MESSAGE
  end

  test "disabled accounts still count and existing accounts can be updated" do
    @setting.update!(max_accounts: Account.count)
    account = accounts(:team_account)
    account.update!(disabled_at: Time.current)
    assert_not @setting.account_creation_allowed?
    account.update!(name: "Still editable")
    assert_equal "Still editable", account.reload.name
  end

  test "rejected user registration rolls back the user and its account" do
    @setting.update!(max_accounts: Account.count)
    assert_no_difference [ "User.count", "Account.count", "Membership.count" ] do
      assert_raises(ActiveRecord::RecordInvalid) { User.register!("capacity-test@example.com") }
    end
  end

  test "site admin actor can exceed limit but normal actor cannot" do
    @setting.update!(max_accounts: 0)
    Current.set(api_user: users(:site_admin_user)) do
      assert @setting.account_creation_allowed?
      assert Account.create!(name: "Admin exception", account_type: :team).persisted?
    end
    Current.set(api_user: users(:user_1)) do
      assert_not @setting.account_creation_allowed?
      assert_not Account.new(name: "Normal user", account_type: :team).save
    end
  end

end
