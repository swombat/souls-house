module Api
  module V1
    module Accounts
      class SubscriptionUsagesController < BaseController

        include ApiAccountAdministration

        before_action :set_administered_account

        def show
          no_store
          unless @account.memberships.confirmed.owners.exists?(user: current_api_user)
            return render_forbidden("Only account owners can read subscription allowances")
          end

          residents = @account.agents.order(:id).map do |agent|
            reading = Agents::SubscriptionUsageSnapshot.cached_allowance(agent)
            { resident_id: agent.to_param }.merge(reading)
          end

          render json: { residents: }
        end

      end
    end
  end
end
