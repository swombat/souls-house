module Api
  module V1
    module Accounts
      # The account's external access page (api_keys#index/destroy): your own
      # keys for this account, and the residents' keys here. Metadata only;
      # tokens are never stored or shown. You may revoke your own keys, as on
      # the web. Creating keys is not here.
      class ApiKeysController < BaseController

        include ApiAccountAdministration

        before_action :set_administered_account, only: :index

        def index
          render json: {
            external_access_keys: external_access_keys.by_creation.map { |key| api_key_json(key) },
            resident_access_keys: resident_access_keys.by_creation.map { |key| api_key_json(key) }
          }
        end

        def destroy
          key = current_api_user.api_keys.where(account: administrable_accounts, agent_id: nil).find(params[:id])
          administer!(key.account)
          key.destroy!
          render json: { revoked: api_key_json(key) }
        end

        private

        def external_access_keys
          current_api_user.api_keys.where(account: @account, agent_id: nil)
        end

        def resident_access_keys
          @account.api_keys.where.not(agent_id: nil).includes(:agent, :user)
        end

        def api_key_json(key)
          {
            id: key.to_param,
            name: key.name,
            prefix: key.display_prefix,
            actor: key.agent ? { type: "agent", id: key.agent.to_param, name: key.agent.name } : { type: "user", id: key.user.to_param, name: key.user.display_name },
            current: key.id == @current_api_key&.id,
            created_at: key.created_at.iso8601,
            last_used_at: key.last_used_at&.iso8601,
            last_used_ip: key.last_used_ip
          }
        end

      end
    end
  end
end
