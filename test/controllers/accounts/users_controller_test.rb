require "test_helper"

class Accounts::UsersControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @team_account = accounts(:team_account)
    @personal_account = accounts(:personal_account)
    sign_in @user
  end

  test "renders users tab with members and permissions for team account" do
    get account_users_path(@team_account), headers: { "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest }
    assert_response :success

    props = inertia_shared_props
    assert_equal @team_account.to_param, props.dig("account", "id")
    assert_equal true, props.fetch("can_manage")
    assert_equal true, props.fetch("can_invite_owner")
    assert_equal @user.id, props.fetch("current_user_id")
    assert props.fetch("members").any? { |member| member["user_id"] == @user.id }
  end

  test "includes pending invitations in members prop" do
    single = accounts(:team_single_user)
    Membership.create!(
      account: single,
      user: users(:existing_user),
      role: "member",
      invited_by: @user
    )

    get account_users_path(single), headers: { "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest }
    assert_response :success
    members = inertia_shared_props.fetch("members")
    assert_equal 2, members.length
    assert_equal 1, members.count { |member| member["invitation_pending"] }
  end

  test "returns empty members list for personal account" do
    get account_users_path(@personal_account), headers: { "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest }
    assert_response :success
    assert_equal [], inertia_shared_props.fetch("members")
  end

  test "nonmembers cannot view another account's users" do
    get account_users_path(accounts(:other))
    assert_response :not_found
  end

  test "requires authentication" do
    delete logout_path
    get account_users_path(@team_account)
    assert_redirected_to login_path
  end

end
