module Api
  module V1
    class ConversationWorkCompletionsController < BaseController

      include ApiHumanConversation
      include WorkCompletionResponse

      before_action :require_chats_feature!

      %w[show create accept grant revoke close].each do |action|
        define_method(action) do
          @chat = current_api_agent ? current_api_agent.chats.kept.find(params[:conversation_id]) : human_chat!
          perform_completion_action(action, agent: current_api_agent, user: current_api_user)
        end
      end

    end
  end
end
