# test/controllers/invitations_controller_test.rb
require "test_helper"

class InvitationsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @admin = users(:admin)
    @account = accounts(:team)
    sign_in @admin
  end

  test "create sends invitation" do
    # Two Membership records: one for personal account, one for team invitation
    assert_difference "Membership.count", 2 do
      # Two emails: one for the new user's personal account confirmation,
      # and one for the team invitation
      assert_enqueued_emails 2 do
        post account_invitations_path(@account), params: {
          email: "newmember@example.com",
          role: "member"
        }
      end
    end

    assert_redirected_to account_path(@account)
    assert_equal "Invitation sent to newmember@example.com", flash[:notice]
  end

  test "create handles validation errors" do
    # Try to invite existing member
    existing = @account.users.first

    assert_no_difference "Membership.count" do
      post account_invitations_path(@account), params: {
        email: existing.email_address,
        role: "member"
      }
    end

    assert_redirected_to account_path(@account)
    assert_match /already a member/, flash[:alert]
  end

  test "resend updates invitation" do
    # Use existing pending invitation fixture
    invitation = memberships(:pending_team_invitation)

    assert_enqueued_emails 1 do
      post resend_account_invitation_path(@account, invitation)
    end

    assert_redirected_to account_path(@account)
    assert_equal "Invitation resent", flash[:notice]
  end

  test "members can invite" do
    member = users(:member)
    sign_in member

    assert_difference "Membership.count", 2 do
      post account_invitations_path(@account), params: {
        email: "member-invited@example.com",
        role: "member"
      }
    end

    assert_redirected_to account_path(@account)
    assert_equal "Invitation sent to member-invited@example.com", flash[:notice]
  end

  test "a member cannot invite someone as owner" do
    sign_in users(:member)

    assert_no_difference -> { @account.memberships.count } do
      post account_invitations_path(@account), params: {
        email: "would-be-owner@example.com",
        role: "owner"
      }
    end

    assert_redirected_to account_path(@account)
    assert_equal "Only an owner can invite someone as owner", flash[:alert]
  end

  test "an owner can invite someone as owner" do
    sign_in users(:owner)

    post account_invitations_path(@account), params: {
      email: "co-owner@example.com",
      role: "owner"
    }

    assert_redirected_to account_path(@account)
    assert_equal "Invitation sent to co-owner@example.com", flash[:notice]
    invited = @account.memberships.joins(:user).find_by!(users: { email_address: "co-owner@example.com" })
    assert invited.owner?
  end

  test "requires account membership" do
    other_account = accounts(:other)
    # Admin doesn't have access to this other account

    post account_invitations_path(other_account), params: {
      email: "test@example.com",
      role: "member"
    }

    assert_response :not_found
  end

  test "personal accounts cannot invite" do
    personal_account = accounts(:personal)
    # Use a user who has access to this personal account
    owner_user = personal_account.users.first
    sign_in owner_user

    post account_invitations_path(personal_account), params: {
      email: "test@example.com",
      role: "owner"
    }

    assert_redirected_to account_path(personal_account)
    # role=owner so the role rule passes and the one-user rule is what refuses.
    assert_match /Personal accounts can only have one user/, flash[:alert]
  end

end
