module Api
  module V1
    class SubscriptionUsagesController < BaseController

      def show
        unless current_api_agent
          return render json: { error: "Subscription usage is only available to agent API keys" }, status: :forbidden
        end

        provider = Agents::Sandbox.subscription_provider_for(current_api_agent)
        unless provider
          return render json: { error: "This resident's model does not use a supported subscription" }, status: :unprocessable_entity
        end

        usage = AgentProviderAuthClient.new(current_api_agent).usage(
          provider:,
          model: Agents::Sandbox.chaos_model_for(current_api_agent),
          refresh: ActiveModel::Type::Boolean.new.cast(params[:refresh])
        )

        render json: usage.merge(
          "model" => Agents::Sandbox.chaos_model_for(current_api_agent),
          "auth_mode" => current_api_agent.provider_auth_mode(provider)
        )
      rescue AgentProviderAuthClient::Error => e
        render json: { error: e.message }, status: e.status || :bad_gateway
      end

    end
  end
end
