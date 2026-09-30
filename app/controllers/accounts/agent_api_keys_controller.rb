module Accounts
  class AgentApiKeysController < ApplicationController

    before_action :require_account

    def show
      render inertia: "accounts/agent_api_keys", props: {
        account: current_account,
        ai_api_keys_configured: current_account.ai_api_keys_configured,
        can_manage_ai_credentials: current_account.ai_credentials_manageable_by?(Current.user),
        subscription_agents: subscription_agents
      }
    end

    def update
      unless current_account.ai_credentials_manageable_by?(Current.user)
        deny_account_access!("Only account owners and administrators can change resident API keys")
        return
      end

      current_account.update!(agent_api_key_params)
      AccountAgentCredentialsRefreshJob.perform_later(current_account.id) if current_account.saved_ai_credentials_change?
      audit_with_changes(:update_agent_api_keys, current_account)
      redirect_to account_agent_api_keys_path(current_account), notice: "Resident API keys updated"
    rescue ActiveRecord::RecordInvalid => e
      redirect_to account_agent_api_keys_path(current_account), alert: e.message
    end

    private

    def subscription_agents
      current_account.agents.externally_hosted.by_name.filter_map do |agent|
        provider = Agents::Sandbox.subscription_provider_for(agent)
        next unless provider

        {
          id: agent.to_param,
          name: agent.name,
          provider: provider,
          provider_name: {
            "anthropic" => "Claude",
            "gemini" => "Google AI",
            "openai" => "ChatGPT",
            "xai" => "xAI"
          }.fetch(provider),
          runtime: agent.runtime,
          available: agent.external? && agent.health_state == "healthy",
          auth_mode: agent.provider_auth_mode(provider),
          connection: agent.provider_connection(provider)
        }
      rescue KeyError
        nil
      end
    end

    def agent_api_key_params
      permitted = params.require(:account).permit(
        *Account::AI_PROVIDERS.keys.map { |provider| "#{provider}_api_key" },
        { clear_ai_api_keys: [] }
      )
      clear_ai_api_keys = Array(permitted.delete("clear_ai_api_keys"))

      Account::AI_PROVIDERS.each_key do |provider|
        attribute = "#{provider}_api_key"
        permitted.delete(attribute) if permitted[attribute].blank?
        permitted[attribute] = nil if clear_ai_api_keys.include?(provider.to_s)
      end

      permitted
    end

  end
end
