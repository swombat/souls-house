module Api
  module V1
    class MessagesController < BaseController

      def create
        chat = conversations_scope.find(params[:conversation_id])

        unless chat.respondable?
          return render json: { error: "Conversation is archived or deleted" }, status: :unprocessable_entity
        end

        message = if current_api_agent
          chat.messages.build(
            content: params[:content],
            role: "assistant",
            agent: current_api_agent
          )
        else
          chat.messages.build(
            content: params[:content],
            role: "user",
            user: current_api_user
          )
        end
        message.attachments.attach(params[:files]) if params[:files].present?

        if message.content.blank? && !message.attachments.attached?
          return render json: { errors: [ "Content or at least one file is required" ] }, status: :unprocessable_entity
        end

        unless message.save
          return render json: { errors: message.errors.full_messages }, status: :unprocessable_entity
        end

        render json: {
          message: message.as_json,
          ai_response_triggered: false
        }, status: :created
      end

      private

      def conversations_scope
        return current_api_agent.chats if current_api_agent

        current_api_account.chats
      end

    end
  end
end
