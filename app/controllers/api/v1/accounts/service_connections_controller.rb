module Api
  module V1
    module Accounts
      # Service connections as accounts/service_connections handles them after
      # they exist: relabel, the two toggles, and disconnect. Connecting needs
      # the provider's consent screen, so it stays on the web. The list is the
      # integrations page's: account-managed connections and your own.
      class ServiceConnectionsController < BaseController

        include ApiAccountAdministration

        before_action :set_connection, only: %i[update destroy]
        before_action :require_connection_manager!, only: %i[update destroy]

        def index
          connections = @account.service_connections.account_managed
            .or(@account.service_connections.personal.where(connected_by_user: current_api_user))
            .includes(:connected_by_user).order(:id)
          render json: { service_connections: connections.map { |connection| connection_json(connection) } }
        end

        def update
          attributes = connection_params
          if attributes[:freely_provisionable].present? && !@connection.owner?(current_api_user)
            attributes.delete(:freely_provisionable)
          end
          @connection.update!(attributes)
          audit(:update_service_connection, @connection,
                provider: @connection.provider,
                enabled_for_new_agents: @connection.enabled_for_new_agents?,
                freely_provisionable: @connection.freely_provisionable?)
          render json: { service_connection: connection_json(@connection) }
        rescue ActiveRecord::RecordInvalid => error
          render_invalid(error.record)
        end

        def destroy
          @connection.disconnect!
          audit(:disconnect_service, @connection, provider: @connection.provider)
          # Keep reviewed provenance and its revoked reference. This does not
          # retain the credential: disconnect! has already erased the payload.
          @connection.destroy! unless @connection.github_resident_imports.exists?
          render json: { disconnected: { id: @connection.public_id, provider: @connection.provider } }
        end

        private

        def set_connection
          @connection = @account.service_connections.find_by_public_id!(params[:id])
        end

        def require_connection_manager!
          render_forbidden("You cannot manage this connection") unless @connection.manageable_by?(current_api_user)
        end

        def connection_params
          params.slice(:label, :enabled_for_new_agents, :freely_provisionable)
            .permit(:label, :enabled_for_new_agents, :freely_provisionable)
        end

        def connection_json(connection)
          connection.as_connection_json(current_user: current_api_user).merge(can_delegate: connection.owner?(current_api_user))
        end

      end
    end
  end
end
