module Api
  module V1
    class MessagesController < BaseController

      def create
        chat = conversations_scope.find(params[:conversation_id])

        unless chat.respondable?
          return render json: { error: "Conversation is archived or deleted" }, status: :unprocessable_entity
        end

        message = if current_api_agent
          # Normalize only resident message content at the post boundary.
          # Arbitrary tool arguments, human posts and stored history are not
          # subject to this cleanup; fenced and inline code remain intact.
          chat.messages.build(
            content: ResidentMessageContent.normalize(params[:content]),
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
        if params.key?(:stone_revision_ids)
          ids = params[:stone_revision_ids]
          unless ids.is_a?(Array) && ids.length <= 10 && ids.all? { |id| id.is_a?(String) }
            return render json: { errors: [ "stone_revision_ids must be an array of at most 10 IDs" ] }, status: :unprocessable_entity
          end
          message.stone_revisions = ids.uniq.map do |id|
            StoneRevision.joins(:stone).where(stones: { chat_id: chat.id, withdrawn_at: nil }).find(id)
          end
        end
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

        draft = if params.key?(:draft_revision)
          return head :forbidden if current_api_agent
          current_api_user.confirmed_accounts.find(chat.account_id)
          ConversationDraft.for(chat: chat, user: current_api_user)
        end
        saved = if draft
          draft.send_message!(message, revision: params[:draft_revision])
        else
          SafeguardConversationPost.save(message)
        end
        unless saved
          return render json: { errors: message.errors.full_messages }, status: :unprocessable_entity
        end

        render json: {
          message: message.as_json,
          draft: draft&.as_json,
          ai_response_triggered: !!message.single_resident_response_triggered
        }, status: :created
      rescue ConversationDraft::Conflict => error
        render json: { errors: [ error.message ], draft: error.draft.as_json }, status: :conflict
      end

      private

      def conversations_scope
        return current_api_agent.chats if current_api_agent

        human_chats
      end

    end
  end
end
