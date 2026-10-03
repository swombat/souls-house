require "test_helper"

class AccountsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @personal_account = accounts(:personal_account)
    @team_account = accounts(:team_account)
    @team_single_user = accounts(:team_single_user)
    # Sign in by posting to login path
    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    # Verify login was successful
    assert_redirected_to root_path
  end

  test "should show account" do
    get account_path(@personal_account)
    assert_response :success
  end

  test "edit without conversion redirects to the general tab, where the name is edited" do
    get edit_account_path(@personal_account)
    assert_redirected_to account_path(@personal_account)
  end

  test "edit with conversion still renders the confirmation page" do
    get edit_account_path(@personal_account, convert: true)
    assert_response :success
  end

  test "should get new" do
    get new_account_path
    assert_response :success
  end

  test "should create personal account" do
    assert_difference -> { Account.count }, 1 do
      assert_difference -> { Membership.count }, 1 do
        post accounts_path, params: {
          account: {
            name: "Writing Room",
            account_type: "personal"
          }
        }
      end
    end

    account = Account.order(:created_at).last
    assert_redirected_to account_chats_path(account)
    assert account.personal?
    assert_equal "Writing Room", account.name
    assert account.owned_by?(@user)
  end

  test "should create team account" do
    assert_difference -> { Account.team.count }, 1 do
      post accounts_path, params: {
        account: {
          name: "New Team",
          account_type: "team"
        }
      }
    end

    account = Account.order(:created_at).last
    assert_redirected_to account_chats_path(account)
    assert_equal "New Team", account.name
    assert account.owned_by?(@user)
  end

  test "should update account name" do
    patch account_path(@team_account), params: { account: { name: "Updated Name" } }
    assert_redirected_to @team_account
    assert_equal "Updated Name", @team_account.reload.read_attribute(:name)
  end

  test "should update personal account name" do
    patch account_path(@personal_account), params: { account: { name: "Focused Work" } }
    assert_redirected_to @personal_account
    assert_equal "Focused Work", @personal_account.reload.name
  end

  test "account owners cannot change shared AI credential fallback" do
    @team_account.update!(use_system_ai_credentials: true)

    patch account_path(@team_account), params: {
      account: { use_system_ai_credentials: false }
    }

    assert_redirected_to @team_account
    assert @team_account.reload.use_system_ai_credentials?
  end

  test "should convert personal to team" do
    patch account_path(@personal_account), params: {
      convert_to: "team",
      account: { name: "Team Account" }
    }
    assert_redirected_to @personal_account
    assert @personal_account.reload.team?
    assert_equal "Team Account", @personal_account.name
    assert_equal "Converted to team account", flash[:notice]
  end

  test "should convert team to personal when only one user" do
    patch account_path(@team_single_user), params: { convert_to: "personal" }
    assert_redirected_to @team_single_user
    assert @team_single_user.reload.personal?
    assert_equal "Converted to personal account", flash[:notice]
  end

  test "should not convert team to personal when multiple users" do
    # Create second user for team account
    second_user = User.create!(email_address: "test2@example.com", password: "password123")
    @team_account.add_user!(second_user)

    patch account_path(@team_account), params: { convert_to: "personal" }
    assert_redirected_to @team_account
    assert @team_account.reload.team? # Should still be team
  end

  test "should handle conversion errors gracefully" do
    # Try to convert to team with invalid name (empty)
    patch account_path(@personal_account), params: {
      convert_to: "team",
      account: { name: "" }
    }
    assert_redirected_to @personal_account
    assert_not_nil flash[:alert]
  end

  test "should require authentication" do
    delete logout_path
    get account_path(@personal_account)
    assert_redirected_to login_path
  end

  test "should only show user's accounts" do
    # Create a completely new user with their own account
    other_user = User.create!(email_address: "isolated@example.com")
    other_user.profile.update!(first_name: "Isolated", last_name: "User")
    other_account = Account.create!(name: "Isolated Account", account_type: :personal)
    other_account.add_user!(other_user, role: "owner", skip_confirmation: true)

    # Try to access the isolated account - should fail
    get account_path(other_account)

    # If the controller works correctly, it should return an error status
    # Since Current.user.accounts should not include this account
    assert_not response.successful?, "Should not have access to isolated account"
  end

  test "confirmed member can manage account settings" do
    member = users(:existing_user)
    sign_in(member)

    patch account_path(@team_account), params: { account: { name: "Nope" } }

    assert_redirected_to @team_account
    assert_equal "Nope", @team_account.reload.read_attribute(:name)
  end

  test "confirmed member cannot replace account AI keys" do
    @team_account.update!(openrouter_api_key: "owner-key")
    member = users(:existing_user)
    sign_in(member)

    patch account_path(@team_account), params: {
      account: {
        name: "Still Collaborative",
        openrouter_api_key: "member-controlled-key",
        clear_ai_api_keys: [ "openrouter" ]
      }
    }

    assert_redirected_to @team_account
    @team_account.reload
    assert_equal "Still Collaborative", @team_account.name
    assert_equal "owner-key", @team_account.openrouter_api_key
  end

  test "unconfirmed invitee cannot access invited account" do
    invited_user = users(:confirmed_user)
    Membership.create!(
      account: @team_account,
      user: invited_user,
      role: "member",
      invited_by: @user
    )

    sign_in(invited_user)

    get account_path(@team_account)
    assert_response :not_found
  end

end
