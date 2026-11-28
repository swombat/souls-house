module Api
  module V1
    module Visiting
      # The still-authorised transcript. Fetching it for a claimed wake is what
      # "delivered" means for a visitor: the run read to here.
      class ConversationsController < BaseController

        TRANSCRIPT_LIMIT = 40

        before_action :authenticate_visit!

        def show
          chat = seated_chat!(params[:id])
          wake = wake_for(chat)
          return render json: { error: "This wake has ended" }, status: :gone if wake && (wake.expired? || wake.completed?)

          messages = chat.messages.kept.includes(:agent, :user).reorder(id: :desc).limit(TRANSCRIPT_LIMIT).to_a.reverse
          wake&.collect!(messages.last&.id)
          render json: {
            conversation: { id: chat.to_param, title: chat.title, account: { name: current_admission.account.name } },
            you: { name: visiting_agent.name },
            participants: chat.agents.map { |agent| { name: agent.name, visiting: agent.visiting? } },
            wake: wake&.as_json,
            messages: messages.map { |message| message_json(message) }
          }
        end

        private

        def message_json(message)
          {
            id: message.to_param,
            speaker: ExternalAgentResponseRequest.speaker_for(message),
            you: message.agent_id == visiting_agent.id,
            role: message.role,
            content: message.content,
            created_at: message.created_at.iso8601,
            attachments: message.attachments_for_api.map { |item| item.slice(:id, :kind, :filename, :content_type, :byte_size) }
          }
        end

      end
    end
  end
end
