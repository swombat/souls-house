module Api
  module V1
    class MessagesController < BaseController

      include ApiHumanConversation

      before_action :require_human_actor!, only: [ :update, :destroy ]
      before_action :require_chats_feature!, only: [ :update, :destroy ]
      before_action :set_authored_message, only: [ :update, :destroy ]

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
        if current_api_agent
          message.handoff_recipient_ids = handoff_recipient_ids(chat)
          return if performed?
        elsif params.key?(:recipient_agent_ids)
          return render json: { errors: [ "recipient_agent_ids is for residents' posts; a person's @mention wakes a resident" ] }, status: :unprocessable_entity
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
          ai_response_triggered: !!message.single_resident_response_triggered,
          handoffs: current_api_agent ? message.handoff_receipts : []
        }, status: :created
      rescue ConversationDraft::Conflict => error
        render json: { errors: [ error.message ], draft: error.draft.as_json }, status: :conflict
      end

      # The author edits their own message, as on the web (messages#update) and
      # the native app. An edit cancels a wake the message asked for that has
      # not been reserved; it never retargets one (Message#update_as_author).
      # Each change takes the message a new revision.
      def update
        content = params[:content]
        unless content.is_a?(String) && content.present?
          return render json: { errors: [ "content is required" ] }, status: :unprocessable_entity
        end

        old_content = @message.content
        if @message.update_as_author(content: content)
          audit_human_action("update_message", @message, account: @message.chat.account, old_content: old_content, new_content: @message.content)
          render json: { message: authored_message_json(@message) }
        else
          render json: { errors: @message.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # Delete is discard: the row stays, hidden from every transcript. A
      # repeat is a no-op that returns the same marker.
      def destroy
        unless @message.discarded?
          audit_human_action("delete_message", @message, account: @message.chat.account, content: @message.content)
          @message.discard_as_author!
        end
        render json: { message: authored_message_json(@message) }
      end

      private

      # Editing reaches only kept messages in kept conversations. Delete also
      # finds an already-discarded message (a repeat is a no-op) and reaches a
      # deleted conversation, so the author can still remove what they wrote.
      def set_authored_message
        deleting = action_name == "destroy"
        chat = human_chat!(deleting ? human_chats.with_discarded : human_chats.kept)
        @message = (deleting ? chat.messages : chat.messages.kept).find(params[:id])
        return if @message.role == "user" && @message.user_id == current_api_user.id

        # Unlike the web, no site-admin override, as in the native-app API.
        render json: { error: "Only the author can change this message" }, status: :forbidden
      end

      def authored_message_json(message)
        return Api::App::V1::Presenter.discarded_marker(message) if message.discarded?

        {
          id: message.to_param,
          conversation_id: message.chat.to_param,
          revision: message.revision,
          discarded: false,
          role: message.role,
          content: message.content,
          updated_at: message.updated_at.iso8601(6)
        }
      end

      def conversations_scope
        return current_api_agent.chats if current_api_agent

        human_chats
      end

      # The residents a resident's post names in recipient_agent_ids, beside
      # any it tags in the content (MessageHandoff). Each must be in the room;
      # naming yourself is ignored.
      def handoff_recipient_ids(chat)
        return [] unless params.key?(:recipient_agent_ids)

        ids = params[:recipient_agent_ids]
        unless ids.is_a?(Array) && ids.length <= 10 && ids.all? { |id| id.is_a?(String) && id.present? }
          render json: { errors: [ "recipient_agent_ids must be an array of at most 10 resident IDs" ] }, status: :unprocessable_entity
          return
        end

        decoded = ids.uniq.map { |id| Agent.decode_id(id) }
        found = chat.agents.where(id: decoded.compact).pluck(:id)
        unless decoded.all? { |id| found.include?(id) }
          render json: { errors: [ "recipient_agent_ids names a resident who is not in this conversation" ] }, status: :unprocessable_entity
          return
        end

        decoded - [ current_api_agent.id ]
      end

    end
  end
end
