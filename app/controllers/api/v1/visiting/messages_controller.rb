module Api
  module V1
    module Visiting
      class MessagesController < BaseController

        before_action :authenticate_visit!

        def create
          chat = seated_chat!
          wake = wake_for(chat)
          message = chat.messages.build(
            content: ResidentMessageContent.normalize(params[:content]),
            role: "assistant",
            agent: visiting_agent
          )
          if message.content.blank?
            return render json: { errors: [ "Content is required" ] }, status: :unprocessable_entity
          end
          if wake && wake.collected? && !wake.completed? && !wake.interaction.finished_at?
            message.runtime_interaction = wake.interaction
          end

          saved = current_admission.with_lock("FOR SHARE") do
            raise ActiveRecord::RecordNotFound unless current_admission.reload.seated_in?(chat)

            SafeguardConversationPost.save(message)
          end
          return render json: { errors: message.errors.full_messages }, status: :unprocessable_entity unless saved

          render json: { message: { id: message.to_param, content: message.content, speaker: visiting_agent.name },
            handoffs: message.handoff_receipts }, status: :created
        end

      end
    end
  end
end
