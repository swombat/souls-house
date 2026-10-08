module Api
  module V1
    # The account a person's key acts in: its name, type, logo colour, members
    # and pending invitations (the web's account page and Interface tab).
    # Renaming mirrors accounts#update (name only; converting the account type
    # is not here). The logo colour mirrors accounts/interfaces#update.
    class AccountsController < BaseController

      include ApiAccountAdministration

      before_action :require_account_manager!, only: :update, if: -> { params.key?(:logo_colour) }

      def show
        render json: { account: account_json }
      end

      def update
        unless params.key?(:name) || params.key?(:logo_colour)
          return render json: { error: "Provide name and/or logo_colour" }, status: :unprocessable_entity
        end
        if params.key?(:name) && !params[:name].is_a?(String)
          return render json: { error: "name must be text" }, status: :unprocessable_entity
        end
        if params.key?(:logo_colour) && !params[:logo_colour].nil? && !params[:logo_colour].is_a?(String)
          return render json: { error: "logo_colour must be text or null" }, status: :unprocessable_entity
        end

        # Check both together first, so a bad colour doesn't leave a half-done rename.
        @account.name = params[:name] if params.key?(:name)
        @account.logo_colour = params[:logo_colour].presence if params.key?(:logo_colour)
        return render_invalid(@account) unless @account.valid?

        @account.restore_attributes
        Account.transaction do
          rename if params.key?(:name)
          update_logo_colour if params.key?(:logo_colour)
        end
        render json: { account: account_json }
      rescue ActiveRecord::RecordInvalid => error
        render_invalid(error.record)
      end

      private

      # accounts#update_account_settings
      def rename
        @account.update!(name: params[:name])
        audit_with_changes(:update_account_settings, @account) if @account.saved_changes.except(:updated_at).any?
      end

      # accounts/interfaces#update
      def update_logo_colour
        @account.update!(logo_colour: params[:logo_colour].presence)
        audit_with_changes(:update_account_logo_colour, @account)
      end

      def account_json
        memberships = @account.members_with_details.to_a
        pending, members = memberships.partition(&:invitation_pending?)

        {
          id: @account.to_param,
          name: @account.name,
          account_type: @account.account_type,
          logo_colour: @account.logo_colour,
          logo_colour_options: Account::LOGO_COLOURS,
          can_manage: @account.manageable_by?(current_api_user),
          can_manage_ai_credentials: @account.ai_credentials_manageable_by?(current_api_user),
          is_owner: @account.owned_by?(current_api_user),
          members: members.map { |membership| membership_json(membership) },
          pending_invitations: pending.map { |membership| membership_json(membership) }
        }
      end

      # The member fields the web shows, without the confirmation token.
      def membership_json(membership)
        {
          id: membership.to_param,
          role: membership.role,
          status: membership.status,
          user: {
            id: membership.user.to_param,
            email_address: membership.user.email_address,
            full_name: membership.user.full_name
          },
          invited_by: membership.invited_by && { id: membership.invited_by.to_param, full_name: membership.invited_by.full_name },
          invited_at: membership.invited_at&.iso8601,
          confirmed_at: membership.confirmed_at&.iso8601,
          can_remove: membership.removable_by?(current_api_user)
        }
      end

    end
  end
end
