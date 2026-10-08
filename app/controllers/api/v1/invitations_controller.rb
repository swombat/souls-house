module Api
  module V1
    # Invitations addressed to the acting person: list the pending ones and accept
    # one. The person already proved control of this email address when they
    # signed up, and the credential acts as them, so accepting here is the same
    # act as following the emailed link while signed in. Declining has no web
    # equivalent and is not offered.
    class InvitationsController < BaseController

      before_action :require_human_actor!

      def index
        invitations = current_api_user.memberships.pending_invitations
          .joins(:account).merge(Account.enabled).includes(:account, :invited_by).order(:created_at)
        render json: { invitations: invitations.map { |m| invitation_json(m) } }
      end

      def accept
        membership = current_api_user.memberships.pending_invitations
          .joins(:account).merge(Account.enabled).find(params[:id])
        membership.confirm!
        audit_human_action("accept_invitation", membership, account: membership.account)
        render json: { invitation: invitation_json(membership.reload) }
      end

      private

      def invitation_json(membership)
        {
          id: membership.to_param,
          account: { id: membership.account.to_param, name: membership.account.name },
          role: membership.role,
          invited_by: membership.invited_by&.full_name.presence || membership.invited_by&.email_address,
          invited_at: membership.created_at.iso8601,
          accepted: membership.confirmed?
        }
      end

    end
  end
end
