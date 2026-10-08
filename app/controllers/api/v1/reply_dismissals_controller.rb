module Api
  module V1
    # chats/reply_dismissals for a person's key: clear one flag (message_id)
    # or every flag up to and including a message (through_message_id).
    class ReplyDismissalsController < BaseController

      include ApiHumanActions
      include ApiReplyAttentionJson

      before_action :require_human_key

      # POST /api/v1/conversations/:conversation_id/reply_dismissal
      def create
        chat = member_account.chats.kept.find(params[:conversation_id])
        message_id = params[:message_id]
        through_id = params[:through_message_id]
        unless [ message_id, through_id ].compact.one? && [ message_id, through_id ].compact.all? { |id| id.is_a?(String) && id.present? }
          render json: { error: "Provide exactly one of message_id or through_message_id" }, status: :unprocessable_entity
          return
        end

        if message_id
          message = chat.messages.kept.find(message_id)
          ReplyExpectation.dismiss_message!(message: message, user: current_api_user)
          audit("dismiss_reply_expectation", chat, message_id: message.to_param)
        else
          through = chat.messages.kept.find(through_id)
          ReplyDismissal.dismiss!(chat: chat, user: current_api_user, through: through)
          audit("dismiss_reply_expectations", chat, through_message_id: through.to_param)
        end

        open = ReplyExpectation.open_message_ids_by_chat(current_api_user, account: member_account, chat: chat)
        render json: { reply_attention: reply_attention_json(chat, open.fetch(chat.id, [])) }
      end

    end
  end
end
