module Api
  module V1
    module Accounts
      # Removing a member or withdrawing a pending invitation, as
      # account_members_controller does on the web (manager). The last owner
      # can't be removed, and nobody can remove themselves.
      class MembersController < BaseController

        include ApiAccountAdministration

        before_action :set_member
        before_action :require_account_manager!

        def destroy
          member = @member
          if (refusal = member.removal_refusal_for(current_api_user))
            return render json: { error: refusal }, status: :unprocessable_entity
          end

          member_email = member.user.email_address
          member_role = member.role
          return render_invalid(member) unless member.destroy

          audit(:remove_member, nil, removed_email: member_email, removed_role: member_role)
          render json: { removed: { id: member.to_param, email_address: member_email, role: member_role } }
        end

        private

        def set_member
          @member = Membership.where(account: administrable_accounts).find(params[:id])
          administer!(@member.account)
        end

      end
    end
  end
end
