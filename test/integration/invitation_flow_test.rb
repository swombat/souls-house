# test/integration/invitation_flow_test.rb
require "test_helper"

class InvitationFlowTest < ActionDispatch::IntegrationTest

  test "complete invitation flow" do
    admin = users(:admin)
    account = accounts(:team)

    # 1. Admin sends invitation
    sign_in admin

    # Two Membership records: personal account + team invitation
    assert_difference "Membership.count", 2 do
      post account_invitations_path(account), params: {
        email: "newuser@example.com",
        role: "member"
      }
    end

    invitation = Membership.last
    assert invitation.invitation?
    assert_equal admin, invitation.invited_by
    assert invitation.invitation_pending?

    # 2. User accepts invitation
    get email_confirmation_path(token: invitation.confirmation_token_for_url)

    invitation.reload
    assert invitation.confirmed?
    assert invitation.invitation_accepted_at.present?
    assert_not invitation.invitation_pending?

    # 3. User can now access the account
    user = invitation.user
    user.update!(password: "ValidPassword123")
    user.profile.update!(first_name: "New", last_name: "User")

    sign_in user
    get account_path(account)
    assert_response :success
  end

  test "admin can resend invitation" do
    admin = users(:admin)
    account = accounts(:team)

    sign_in admin

    # Create pending invitation
    post account_invitations_path(account), params: {
      email: "pending@example.com",
      role: "member"
    }

    invitation = Membership.last
    original_token = invitation.confirmation_token_for_url
    original_time = invitation.invited_at

    # Resend invitation
    travel 1.hour do
      assert_enqueued_emails 1 do
        post resend_account_invitation_path(account, invitation)
      end
    end

    invitation.reload
    assert_not_equal original_token, invitation.confirmation_token_for_url
    assert_not_equal original_time, invitation.invited_at
  end

  test "members can invite other members" do
    member = users(:member)
    account = accounts(:team)

    sign_in member

    assert_difference "Membership.count", 2 do
      post account_invitations_path(account), params: {
        email: "unauthorized@example.com",
        role: "member"
      }
    end

    assert_redirected_to account_users_path(account)
    assert_match /Invitation sent/, flash[:notice]
  end

  test "members can remove other members" do
    member = users(:member)
    account = accounts(:team)

    sign_in member

    assert_difference "Membership.count", -1 do
      delete account_member_path(account, memberships(:team_admin_member))
    end

    assert_redirected_to account_users_path(account)
    assert_match /Member removed successfully/, flash[:notice]
  end

  test "members can resend invitations" do
    member = users(:member)
    account = accounts(:team)
    invitation = memberships(:pending_team_invitation)

    sign_in member

    assert_enqueued_emails 1 do
      post resend_account_invitation_path(account, invitation)
    end

    assert_redirected_to account_users_path(account)
    assert_match /Invitation resent/, flash[:notice]
  end

  test "members still cannot invite into personal accounts" do
    owner = users(:owner)
    personal_account = accounts(:personal)

    sign_in owner

    post account_invitations_path(personal_account), params: {
      email: "shouldfail@example.com",
      role: "member"
    }

    assert_redirected_to account_users_path(personal_account)
    assert_match /Personal accounts can only have one user/, flash[:alert]
  end

  test "cannot remove last owner from account" do
    # Use existing fixtures
    account = accounts(:team_single_user)
    owner = users(:user_1)
    owner_membership = memberships(:team_single_user_member)

    sign_in owner

    # Try to remove the owner
    assert_no_difference "Membership.count" do
      delete account_member_path(account, owner_membership)
    end

    assert_redirected_to account_users_path(account)
    assert_match /Cannot remove the last owner/, flash[:alert]
  end

end
