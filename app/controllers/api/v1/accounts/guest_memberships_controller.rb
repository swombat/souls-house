module Api
  module V1
    module Accounts
      # Guest residents, as accounts/guest_memberships and the residents page
      # handle them on the web. Adding needs someone who belongs to both the
      # resident's home and this account (GuestMembership.candidates_for);
      # removing needs an owner of either side (GuestMembership#removable_by?).
      # A resident leaving by its own key is Api::V1::GuestMembershipsController.
      class GuestMembershipsController < BaseController

        include ApiAccountAdministration

        before_action :set_administered_account, only: %i[index create]
        before_action -> { require_feature_enabled!(:agents) }

        def index
          render json: {
            guests: @account.guest_memberships.includes(:account, agent: :account).order(:created_at).map(&:as_json),
            away: GuestMembership.where(agent: @account.agents).includes(:account, agent: :account).order(:created_at).map(&:as_json),
            candidates: GuestMembership.candidates_for(account: @account, user: current_api_user)
              .includes(:account).by_name.map { |agent| { id: agent.to_param, name: agent.name, home_account_name: agent.account.name } },
            can_end_guest_memberships: @account.owned_by?(current_api_user)
          }
        end

        def create
          agent = GuestMembership.candidates_for(account: @account, user: current_api_user).find(params.require(:agent_id))
          membership = @account.guest_memberships.create!(agent: agent, added_by: current_api_user)
          audit("add_guest_resident", membership, agent_id: agent.id, home_account_id: agent.account_id)
          render json: { guest_membership: membership.as_json }, status: :created
        rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid
          render json: { error: "That resident can't be added as a guest here" }, status: :unprocessable_entity
        end

        # The receiving account removes its guest, or the hosting account
        # withdraws its resident. Either side is enough.
        def destroy
          accounts = administrable_accounts
          membership = GuestMembership
            .where(account: accounts)
            .or(GuestMembership.where(agent_id: Agent.where(account: accounts).select(:id)))
            .find(params[:id])
          # Act as the receiving account when the person is there, else as the home.
          administer!(accounts.exists?(membership.account_id) ? membership.account : membership.agent.account)
          return render_forbidden("You don't have permission to change this guest") unless membership.removable_by?(current_api_user)

          membership.destroy!
          audit("remove_guest_resident", membership, agent_id: membership.agent_id, account_id: membership.account_id)
          render json: { removed: membership.as_json }
        end

      end
    end
  end
end
