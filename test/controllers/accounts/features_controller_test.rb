require "test_helper"

class Accounts::FeaturesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:existing_user)
    @account = accounts(:team_account)
    sign_in @user
  end

  test "Features carries the account's switches and the site's scopes" do
    Setting.instance.update!(voice_mode_scope: "enabled", speech_engine_scope: "account_choice")
    @account.update!(show_chat_codes: true)
    get account_features_path(@account), headers: { "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest }
    assert_response :success
    assert_equal "accounts/features", inertia_component
    props = inertia_shared_props
    assert_equal true, props["show_chat_codes"]
    assert_equal "enabled", props["voice_mode_site_scope"]
    assert_equal "account_choice", props["speech_engine_site_scope"]
    assert_equal @account.resident_handoff_cap, props["resident_handoff_cap"]
    assert_equal @account.stalled_thread_wake_cap, props["stalled_thread_wake_cap"]
  end

  test "General no longer carries the feature switches" do
    get account_path(@account), headers: { "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest }
    assert_response :success
    assert_nil inertia_shared_props["show_chat_codes"]
    assert_nil inertia_shared_props["resident_handoff_cap"]
    assert_nil inertia_shared_props["stalled_thread_wake_cap"]
  end

  test "a feature switch returns to Features and a rename returns to General" do
    patch account_path(@account), params: { account: { show_chat_codes: true } }
    assert_redirected_to account_features_path(@account)

    patch account_path(@account), params: { account: { name: "Renamed" } }
    assert_redirected_to account_path(@account)
  end

  test "nonmembers cannot see another account's features" do
    get account_features_path(accounts(:other))
    assert_response :not_found
  end

end
