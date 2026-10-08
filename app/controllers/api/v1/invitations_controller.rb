module Api
  module V1
    # Invitations addressed to the acting person: list them and accept one.
    #
    # Authority follows the credential (#232's contract). An OAuth sign-in acts
    # for the person across accounts, so it may join any enabled account that
    # invited them: the same act as following the emailed link while signed in.
    # An API key is delegated for one account only, so it reaches invitations
    # into that account and no other; joining a new account needs the person's
    # OAuth sign-in. Declining has no web equivalent and is not offered.
    #
    # Accepting is idempotent: repeating it for an invitation this person has
    # already accepted answers 200 with accepted: true and changes nothing.
    class InvitationsController < BaseController

      before_action :require_human_actor!

      def index
        render json: { invitations: reachable_invitations.pending_invitations.order(:created_at).map { |m| invitation_json(m) } }
      end

      def accept
        membership = reachable_invitations.find(params[:id])
        unless membership.confirmed?
          membership.confirm!
          audit_human_action("accept_invitation", membership, account: membership.account)
        end
        render json: { invitation: invitation_json(membership.reload) }
      end

      private

      # Invitations (pending or accepted) addressed to this person, in enabled
      # accounts this credential may reach.
      def reachable_invitations
        scope = current_api_user.memberships.where.not(invited_by_id: nil)
          .joins(:account).merge(Account.enabled).includes(:account, :invited_by)
        app_token_request? ? scope : scope.where(account_id: current_api_account.id)
      end

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
