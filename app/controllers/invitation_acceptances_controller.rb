# Accepting an invitation from inside the app, for someone already signed in:
# the same act as following the emailed link (Membership#confirm!), reached
# from the envelope in the account menu. Only the invited person's own
# pending invitations into enabled accounts can be found here.
class InvitationAcceptancesController < ApplicationController

  def create
    membership = PendingInvitations.scope_for(Current.user).find(params[:invitation_id])
    membership.confirm!
    AuditLog.create!(
      user: Current.user,
      account: membership.account,
      action: "accept_invitation",
      auditable: membership,
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )
    redirect_to "/accounts/#{membership.account.to_param}/chats",
      notice: "You've joined #{membership.account.name}"
  end

end
