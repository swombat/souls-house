require "test_helper"

class Admin::BillingSwitchesTest < ActionDispatch::IntegrationTest

  test "only a site admin can change whether an account pays, and it is audited" do
    account = accounts(:team_account)
    sign_in(users(:regular_user))
    patch billing_required_admin_account_path(account), params: { account: { billing_required: true } }
    assert_not account.reload.billing_required?

    sign_in(users(:site_admin_user))
    assert_difference -> { AuditLog.where(action: "admin_update_account_billing_required").count }, 1 do
      patch billing_required_admin_account_path(account), params: { account: { billing_required: true } }
    end
    assert account.reload.billing_required?

    patch billing_required_admin_account_path(account), params: { account: { billing_required: false } }
    assert_not account.reload.billing_required?
  end

  test "the site switch is saved from settings and its status is shown" do
    accounts(:team_account).update!(billing_required: true)
    sign_in(users(:site_admin_user))

    get admin_settings_path
    billing = inertia_shared_props.fetch("billing")
    assert_equal 1, billing.fetch("accounts_required")
    assert_equal false, billing.fetch("payment_open")

    patch admin_settings_path, params: { setting: { billing_enabled: true } }
    assert Setting.instance.reload.billing_enabled?
    assert_predicate Setting.instance.billing_enabled_at, :present?
  end

  test "the free trial is offered by default and switched in Site Admin" do
    sign_in(users(:site_admin_user))
    assert Setting.instance.free_trial_enabled?

    get admin_settings_path
    assert_equal true, inertia_shared_props.fetch("billing").fetch("free_trial_enabled")
    assert_equal true, inertia_shared_props.fetch("setting").fetch("free_trial_enabled")

    patch admin_settings_path, params: { setting: { free_trial_enabled: false } }
    assert_not Setting.instance.reload.free_trial_enabled?
    @inertia_props = nil
    get admin_settings_path
    assert_equal false, inertia_shared_props.fetch("billing").fetch("free_trial_enabled")

    patch admin_settings_path, params: { setting: { billing_enabled: true } }
    assert_not Setting.instance.reload.free_trial_enabled?, "another switch's save leaves it alone"
  end

end
