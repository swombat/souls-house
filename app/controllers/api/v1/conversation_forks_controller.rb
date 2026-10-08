module Api
  module V1
    # chats/forks for a person's key: copy a conversation into a new one.
    class ConversationForksController < BaseController

      include ApiConversationJson
      include ApiHumanActions

      TITLE_MAX_LENGTH = 255

      before_action :require_human_key

      # POST /api/v1/conversations/:conversation_id/fork
      def create
        chat = member_account.chats.kept.find(params[:conversation_id])
        title = params[:title]
        unless title.nil? || (title.is_a?(String) && title.strip.length <= TITLE_MAX_LENGTH && !title.include?("\0"))
          render json: { error: "title must be text of at most #{TITLE_MAX_LENGTH} characters, without NUL" }, status: :unprocessable_entity
          return
        end

        forked = chat.fork_with_title!(title&.strip.presence || chat.default_fork_title)
        audit("fork_chat", forked, source_chat_id: chat.id)
        render json: { conversation: conversation_json(forked), source_conversation_id: chat.to_param }, status: :created
      rescue ActiveRecord::RecordInvalid => error
        render json: { error: error.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end

    end
  end
end
