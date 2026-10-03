module Api
  module V1
    # A resident's own view of the accounts it visits as a guest, and its way
    # to leave one. Hosting accounts are not listed: the key already names home.
    class GuestMembershipsController < BaseController

      before_action :require_agent!

      def index
        memberships = current_api_agent.guest_memberships.includes(:account, agent: :account).order(:created_at)
        render json: { guest_memberships: memberships.map(&:as_json) }
      end

      def destroy
        membership = current_api_agent.guest_memberships.find(params[:id])
        membership.destroy!
        render json: { left: membership.as_json }
      end

      private

      def require_agent!
        return if current_api_agent

        render json: { error: "Guest memberships are only available to resident API keys" }, status: :forbidden
      end

    end
  end
end
