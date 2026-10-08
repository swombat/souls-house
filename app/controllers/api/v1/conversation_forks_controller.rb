module Api
  module V1
    # chats/forks for a person's credential: copy a conversation into a new one
    # in the same account.
    class ConversationForksController < BaseController

      include ApiConversationJson
      include ApiHumanConversation

      TITLE_MAX_LENGTH = 255

      before_action :require_human_actor!
      before_action :require_chats_feature!

      # POST /api/v1/conversations/:conversation_id/fork
      def create
        chat = human_chat!
        title = params[:title]
        unless title.nil? || (title.is_a?(String) && title.strip.length <= TITLE_MAX_LENGTH && !title.include?("\0"))
          render json: { error: "title must be text of at most #{TITLE_MAX_LENGTH} characters, without NUL" }, status: :unprocessable_entity
          return
        end

        forked = chat.fork_with_title!(title&.strip.presence || chat.default_fork_title)
        audit_human_action("fork_chat", forked, account: chat.account, source_chat_id: chat.id)
        render json: { conversation: conversation_json(forked), source_conversation_id: chat.to_param }, status: :created
      rescue ActiveRecord::RecordInvalid => error
        render json: { error: error.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end

    end
  end
end
