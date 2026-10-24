module Api
  module V1
    module Accounts
      # Service connections as accounts/service_connections handles them:
      # connect from pasted credentials, relabel, the two toggles, and
      # disconnect. Services that need the provider's consent screen (OAuth)
      # or a QR pairing still connect on the web; `providers` says which can
      # be connected here and what each one asks for. The list is the
      # integrations page's: account-managed connections and your own.
      class ServiceConnectionsController < BaseController

        include ApiAccountAdministration

        before_action :set_administered_account, only: %i[index create providers]
        before_action :set_connection, only: %i[update destroy]
        before_action :require_connection_manager!, only: %i[update destroy]

        def index
          connections = @account.service_connections.account_managed
            .or(@account.service_connections.personal.where(connected_by_user: current_api_user))
            .includes(:connected_by_user).order(:id)
          render json: { service_connections: connections.map { |connection| connection_json(connection) } }
        end

        # GET /api/v1/account/service_connections/providers
        def providers
          render json: { providers: api_connectable_definitions.map { |definition| provider_json(definition) } }
        end

        # POST /api/v1/account/service_connections
        # { provider, management_scope?, label?, credentials: { <field>: value } }
        def create
          definition = Services::Definition.fetch(params.require(:provider))
          unless api_connectable_definitions.include?(definition)
            return render json: { error: "#{definition.name} connects on the web (Integrations), not through the API" }, status: :unprocessable_entity
          end

          management_scope = params[:management_scope].presence || "personal"
          if management_scope == "account_managed" && !@account.service_credentials_manageable_by?(current_api_user)
            return render_forbidden("Only account admins can add a connection the account manages")
          end

          connection = ServiceConnection.connect_with_credentials!(
            account: @account,
            user: current_api_user,
            definition: definition,
            management_scope: management_scope,
            credentials: credential_params(definition)
          )
          connection.update!(label: params[:label]) if params[:label].present?
          audit(:connect_service, connection,
                provider: connection.provider,
                management_scope: connection.management_scope,
                external_identity: connection.external_identity,
                authority_summary: connection.credential_metadata["authority_summary"])
          render json: { service_connection: connection_json(connection) }, status: :created
        rescue Services::Definition::UnknownProvider => error
          render json: { error: error.message }, status: :not_found
        rescue Services::AdapterError, ActionController::ParameterMissing => error
          render json: { error: error.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => error
          render_invalid(error.record)
        end

        def update
          attributes = connection_params
          # Delegation is the personal owner's alone; JSON false must not slip past.
          if attributes.key?(:freely_provisionable) && !@connection.owner?(current_api_user)
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
          # Keep reviewed provenance or comms history and the revoked
          # reference. disconnect! has already erased the credential.
          @connection.destroy! unless @connection.retained_after_disconnect?
          render json: { disconnected: { id: @connection.public_id, provider: @connection.provider } }
        end

        private

        # Credentials-only services: everything the web connects with a form
        # and no QR. Pairing (WhatsApp, Telegram) needs a phone in hand.
        def api_connectable_definitions
          Services::Definition.all.select { |definition| definition.connection_method == "credentials" && definition.available? }
        end

        def provider_json(definition)
          {
            key: definition.key,
            name: definition.name,
            management_scopes: definition.management_scopes,
            credential_fields: definition.credential_fields.map { |field| field.slice("key", "label", "type", "help") },
            documentation: definition.documentation
          }
        end

        # Each provider's declared fields; nothing else passes. Missing ones
        # reach the adapter blank, and it names what is required.
        def credential_params(definition)
          keys = definition.credential_fields.map { |field| field.fetch("key") }
          return {} if keys.empty?

          raw = params[:credentials]
          raise ActionController::ParameterMissing, :credentials unless raw.respond_to?(:permit)

          raw.permit(*keys).to_h
        end

        def set_connection
          @connection = ServiceConnection.where(account: administrable_accounts).find_by_public_id!(params[:id])
          administer!(@connection.account)
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
