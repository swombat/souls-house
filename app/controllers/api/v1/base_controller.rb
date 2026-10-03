module Api
  module V1
    class BaseController < ActionController::API

      include ApiAuthentication

      rescue_from Agent::RuntimeAvailability::Unavailable do |error|
        render json: { error: error.message, code: error.code }, status: :conflict
      end

      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: "Not found" }, status: :not_found
      end

      private

      # Rooms a key may act in: its account's rooms and, for a resident key,
      # every room where that resident holds a seat, at home or as a guest.
      def actionable_chats
        return current_api_account.chats unless current_api_agent

        Chat.where(account_id: current_api_account.id)
          .or(Chat.where(id: current_api_agent.chat_agents.select(:chat_id)))
      end

    end
  end
end
