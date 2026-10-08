module Api
  module V1
    # Where the key's person has been flagged to respond (the web's red eye,
    # ReplyAttentionEye.svelte). This is about the person, not a resident: it
    # never touches a resident's pending reply.
    class ReplyAttentionsController < BaseController

      include ApiHumanActions
      include ApiReplyAttentionJson

      before_action :require_human_key

      # GET /api/v1/reply_attention
      def show
        open = ReplyExpectation.open_message_ids_by_chat(current_api_user, account: member_account)
        chats = member_account.chats.where(id: open.keys).index_by(&:id)
        # Most recently flagged first.
        conversations = open.sort_by { |_chat_id, message_ids| -message_ids.max }
          .map { |chat_id, message_ids| reply_attention_json(chats.fetch(chat_id), message_ids) }
        render json: { total: conversations.size, conversations: conversations }
      end

    end
  end
end
