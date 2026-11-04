require "test_helper"

class InvitationAcceptancesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @inviter = users(:existing_user)
    @account = accounts(:other)
    @invitation = Membership.create!(account: @account, user: @user, role: "member", invited_by: @inviter)
  end

  test "the navbar carries the signed-in person's pending invitations" do
    sign_in(@user)
    get edit_user_path
    summary = inertia_props.fetch("props").fetch("pending_invitations")

    assert_equal 1, summary.fetch("total")
    item = summary.fetch("items").sole
    assert_equal @invitation.to_param, item.fetch("id")
    assert_equal @account.name, item.fetch("account_name")
    assert_equal "member", item.fetch("role")
  end

  test "accepting joins the account, audits it, and opens its chats" do
    sign_in(@user)

    assert_difference -> { AuditLog.where(action: "accept_invitation").count }, 1 do
      post accept_invitation_path(@invitation)
    end

    assert_redirected_to "/accounts/#{@account.to_param}/chats"
    assert @invitation.reload.confirmed?
    assert_includes @user.reload.confirmed_accounts, @account
    assert_equal 0, PendingInvitations.summary_for(@user)[:total]
  end

  test "nobody can accept someone else's invitation" do
    sign_in(@inviter)
    post accept_invitation_path(@invitation)

    assert_not @invitation.reload.confirmed?
  end

  test "an invitation into a disabled account is neither shown nor accepted" do
    @account.update_column(:disabled_at, Time.current)
    assert_equal 0, PendingInvitations.summary_for(@user)[:total]

    sign_in(@user)
    post accept_invitation_path(@invitation)
    assert_not @invitation.reload.confirmed?
  end

end
