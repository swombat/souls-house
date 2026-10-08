module Api
  module V1
    # chats/reply_dismissals for a person's credential: clear one flag
    # (message_id) or every flag up to and including a message
    # (through_message_id).
    class ReplyDismissalsController < BaseController

      include ApiHumanConversation
      include ApiReplyAttentionJson

      before_action :require_human_actor!
      before_action :require_chats_feature!

      # POST /api/v1/conversations/:conversation_id/reply_dismissal
      def create
        chat = human_chat!
        message_id = params[:message_id]
        through_id = params[:through_message_id]
        unless [ message_id, through_id ].compact.one? && [ message_id, through_id ].compact.all? { |id| id.is_a?(String) && id.present? }
          render json: { error: "Provide exactly one of message_id or through_message_id" }, status: :unprocessable_entity
          return
        end

        if message_id
          message = chat.messages.kept.find(message_id)
          ReplyExpectation.dismiss_message!(message: message, user: current_api_user)
          audit_human_action("dismiss_reply_expectation", chat, account: chat.account, message_id: message.to_param)
        else
          through = chat.messages.kept.find(through_id)
          ReplyDismissal.dismiss!(chat: chat, user: current_api_user, through: through)
          audit_human_action("dismiss_reply_expectations", chat, account: chat.account, through_message_id: through.to_param)
        end

        open = ReplyExpectation.open_message_ids_by_chat(current_api_user, account: chat.account, chat: chat)
        render json: { reply_attention: reply_attention_json(chat, open.fetch(chat.id, [])) }
      end

    end
  end
end
