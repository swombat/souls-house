module Api
  module V1
    module Accounts
      # The account's own model provider keys (accounts/agent_api_keys).
      # Write-only: the read says which providers have a key, never the key.
      # Changing them needs an owner or admin, as on the web.
      #
      # A key travels as `<provider>_api_key`, the web form's field name, so the
      # request log's parameter filter (`_key`) masks it. Any other shape for a
      # key is refused.
      class AiProviderKeysController < BaseController

        include ApiAccountAdministration

        before_action :set_administered_account

        KEY_PARAM = /\A(.+)_api_key\z/

        def show
          render json: ai_provider_keys_json
        end

        # { "anthropic_api_key": "sk-...", "clear": ["openai"] }
        def update
          unless @account.ai_credentials_manageable_by?(current_api_user)
            return render_forbidden("Only account owners and administrators can change model API keys")
          end

          changes = ai_provider_key_changes
          return render(json: { error: changes[:error], providers: Account::AI_PROVIDERS.keys }, status: :unprocessable_entity) if changes[:error]

          @account.update_ai_api_keys!(set: changes[:set], clear: changes[:clear])
          audit_with_changes(:update_agent_api_keys, @account)
          render json: ai_provider_keys_json
        rescue ActiveRecord::RecordInvalid => error
          render_invalid(error.record)
        end

        private

        # { set: { "anthropic" => "sk-..." }, clear: ["openai"] }, or { error: }.
        def ai_provider_key_changes
          if params.key?(:set)
            return { error: "Send each key as <provider>_api_key, for example anthropic_api_key" }
          end

          known = Account::AI_PROVIDERS.keys.map(&:to_s)
          set = {}
          unknown = []
          params.each_key do |name|
            next unless (provider = name.to_s[KEY_PARAM, 1])

            value = params[name]
            return { error: "#{name} must be text" } unless value.is_a?(String)

            known.include?(provider) ? set[provider] = value : unknown << provider
          end

          clear = params.key?(:clear) ? params[:clear] : []
          return { error: "clear must list provider names" } unless clear.is_a?(Array) && clear.all?(String)

          unknown |= clear - known
          return { error: "Unknown provider: #{unknown.join(', ')}" } if unknown.any?
          return { error: "Provide <provider>_api_key and/or clear" } if set.empty? && clear.empty?

          { set: set, clear: clear }
        end

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
