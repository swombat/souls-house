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
        message.progress_message = ActiveModel::Type::Boolean.new.cast(params[:progress]) || false
        message.attachments.attach(params[:files]) if params[:files].present?
        if params[:runtime_run_id].present?
          return head :forbidden unless current_api_agent
          interaction = chat.agent_runtime_interactions.find_by!(
            run_id: params[:runtime_run_id], agent: current_api_agent
          )
          return head :unprocessable_entity unless interaction.dispatch_claimed_at &&
            interaction.activity_token_expires_at&.future?
          message.runtime_interaction = interaction
        end

        if message.content.blank? && !message.attachments.attached?
          return render json: { errors: [ "Content or at least one file is required" ] }, status: :unprocessable_entity
        end

        if message.progress_message?
          return head :unprocessable_entity unless interaction
          saved = interaction.with_lock do
            if interaction.finished_at? || interaction.execution_state.in?(AgentRuntimeInteraction::TERMINAL_STATES) ||
                !interaction.execution_deadline_at&.future?
              message.errors.add(:runtime_interaction, "is no longer live")
              false
            else
              message.save
            end
          end
        else
          saved = message.save
        end

        unless saved
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
