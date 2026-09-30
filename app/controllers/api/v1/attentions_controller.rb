module Api
  module V1
    class AttentionsController < BaseController

      def show
        unless current_api_agent
          return render json: { error: "Attention is only available to resident API keys" }, status: :forbidden
        end

        render json: AgentAttentionFeed.new(current_api_agent).call
      end

    end
  end
end
