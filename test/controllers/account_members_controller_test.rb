# test/controllers/account_members_controller_test.rb
require "test_helper"

class AccountMembersControllerTest < ActionDispatch::IntegrationTest

  setup do
    @admin = users(:admin)
    @account = accounts(:team)
    sign_in @admin
  end

  test "destroy removes member" do
    # Use existing fixture member that can be removed
    member = memberships(:team_member_user)

    assert_difference "@account.memberships.count", -1 do
      delete account_member_path(@account, member)
    end

    assert_redirected_to account_users_path(@account)
    assert_equal "Member removed successfully", flash[:notice]
  end

  test "destroy handles last owner error" do
    # Use team_single_user fixture which has only one owner
    single_account = accounts(:team_single_user)
    owner_membership = memberships(:team_single_user_member)

    # Give admin access to test the removal
    sign_in users(:user_1)  # This user owns team_single_user

    assert_no_difference "single_account.memberships.count" do
      delete account_member_path(single_account, owner_membership)
    end

    assert_redirected_to account_users_path(single_account)
    assert_match /Cannot remove the last owner/, flash[:alert]
  end

  test "requires account membership for destroy" do
    # Try to delete a member from an account the user doesn't belong to
    other_account = accounts(:personal)  # Account that admin doesn't belong to
    other_member = memberships(:daniel_personal)

    delete account_member_path(other_account, other_member)
    assert_response :not_found
  end

  test "member can remove another member" do
    sign_in users(:member)

    assert_difference "@account.memberships.count", -1 do
      delete account_member_path(@account, memberships(:team_admin_member))
    end

    assert_redirected_to account_users_path(@account)
    assert_equal "Member removed successfully", flash[:notice]
  end

end
