module Api
  module V1
    module Accounts
      # Inviting someone into the account and resending a pending invitation,
      # as invitations_controller does on the web (manager).
      class InvitationsController < BaseController

        include ApiAccountAdministration

        before_action :require_account_manager!

        def create
          email = params[:email].to_s
          role = params[:role].to_s
          invitation = @account.invite_member(email: email, role: role, invited_by: current_api_user)
          return render_invalid(invitation) unless invitation.save

          audit(:invite_member, invitation, invited_email: email, role: role)
          render json: { invitation: invitation_json(invitation) }, status: :created
        end

        # The id is the pending membership's, from GET /api/v1/account.
        def resend
          member = @account.memberships.find(params[:id])
          unless member.resend_invitation!
            return render json: { error: "Could not resend invitation" }, status: :unprocessable_entity
          end

          audit(:resend_invitation, member, member_email: member.user.email_address, role: member.role)
          render json: { invitation: invitation_json(member) }
        end

        private

        def invitation_json(membership)
          {
            id: membership.to_param,
            email_address: membership.user.email_address,
            role: membership.role,
            status: membership.status,
            invited_at: membership.invited_at&.iso8601
          }
        end

      end
    end
  end
end
