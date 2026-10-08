module Api
  module V1
    module Accounts
      # The account's own model provider keys (accounts/agent_api_keys).
      # Write-only: the read says which providers have a key, never the key.
      # Changing them needs an owner or admin, as on the web.
      class AiProviderKeysController < BaseController

        include ApiAccountAdministration

        def show
          render json: ai_provider_keys_json
        end

        # { "set": { "anthropic": "sk-..." }, "clear": ["openai"] }
        def update
          unless @account.ai_credentials_manageable_by?(current_api_user)
            return render_forbidden("Only account owners and administrators can change model API keys")
          end

          set = params[:set].presence || {}
          clear = params[:clear].presence || []
          unless set.is_a?(ActionController::Parameters) && clear.is_a?(Array) && clear.all?(String) &&
              set.values.all?(String)
            return render json: { error: "set must map provider names to keys and clear must list provider names" },
                          status: :unprocessable_entity
          end

          unknown = (set.keys + clear).map(&:to_s) - Account::AI_PROVIDERS.keys.map(&:to_s)
          if unknown.any?
            return render json: { error: "Unknown provider: #{unknown.uniq.join(', ')}", providers: Account::AI_PROVIDERS.keys },
                          status: :unprocessable_entity
          end

          @account.update_ai_api_keys!(set: set.to_unsafe_h, clear: clear)
          audit_with_changes(:update_agent_api_keys, @account)
          render json: ai_provider_keys_json
        rescue ActiveRecord::RecordInvalid => error
          render_invalid(error.record)
        end

        private

        def ai_provider_keys_json
          {
            ai_api_keys_configured: @account.ai_api_keys_configured,
            use_system_ai_credentials: @account.use_system_ai_credentials?,
            can_manage_ai_credentials: @account.ai_credentials_manageable_by?(current_api_user)
          }
        end

      end
    end
  end
end
