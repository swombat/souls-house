module Api
  module V1
    class ConversationWorkStatusesController < BaseController

      include ApiHumanConversation
      include WorkStatusResponse

      before_action :require_chats_feature!

      def update
        @chat = if current_api_agent
          current_api_agent.chats.kept.find(params[:conversation_id])
        else
          human_chat!
        end
        update_work_status(agent: current_api_agent, user: current_api_user)
      end

    end
  end
end
