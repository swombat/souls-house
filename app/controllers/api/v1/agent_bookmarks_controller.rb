module Api
  module V1
    class AgentBookmarksController < BaseController

      PAGE_SIZE = 100

      before_action :require_agent!
      before_action :set_membership, except: :index

      def index
        scope = owned_bookmarks.order(id: :desc)
        if params[:cursor].present?
          unless params[:cursor].is_a?(String) && params[:cursor].match?(/\A[a-zA-Z0-9]{1,100}\z/)
            return render json: { error: "Invalid cursor" }, status: :unprocessable_entity
          end
          cursor = owned_bookmarks.find(params[:cursor])
          scope = scope.where("agent_bookmarks.id < ?", cursor.id)
        end
        bookmarks = scope.includes(chat_agent: :chat).limit(PAGE_SIZE + 1).to_a
        next_cursor = bookmarks.length > PAGE_SIZE ? bookmarks[PAGE_SIZE - 1].to_param : nil
        render json: { bookmarks: bookmarks.first(PAGE_SIZE).map { |bookmark| bookmark_json(bookmark) }, next_cursor: next_cursor }
      end

      def show
        bookmark = @membership.agent_bookmark
        raise ActiveRecord::RecordNotFound unless bookmark

        render json: { bookmark: bookmark_json(bookmark) }
      end

      def update
        unless params[:note].is_a?(String)
          return render json: { error: "note must be a nonblank string of at most 2000 characters" }, status: :unprocessable_entity
        end

        # Serialize creation/replacement for this membership, including first writes.
        @membership.with_lock do
          bookmark = @membership.agent_bookmark || @membership.build_agent_bookmark
          if bookmark.update(note: params[:note])
            render json: { bookmark: bookmark_json(bookmark) }
          else
            render json: { errors: bookmark.errors.full_messages }, status: :unprocessable_entity
          end
        end
      end

      def destroy
        @membership.with_lock { @membership.agent_bookmark&.destroy! }
        head :no_content
      end

      private

      def require_agent!
        response.headers["Cache-Control"] = "no-store"
        return if current_api_agent

        render json: { error: "Bookmarks are only available to resident API keys" }, status: :forbidden
      end

      def set_membership
        chat = current_api_account.chats.find(params[:conversation_id])
        @membership = current_api_agent.chat_agents.find_by!(chat_id: chat.id)
      end

      def owned_bookmarks
        AgentBookmark.joins(chat_agent: :chat).where(
          chat_agents: { agent_id: current_api_agent.id }, chats: { account_id: current_api_account.id }
        )
      end

      def bookmark_json(bookmark)
        chat = bookmark.chat_agent.chat
        {
          id: bookmark.to_param, conversation_id: chat.to_param,
          title: chat.title_or_default, note: bookmark.note,
          detail_path: api_v1_conversation_path(chat),
          created_at: bookmark.created_at.iso8601, updated_at: bookmark.updated_at.iso8601
        }
      end

    end
  end
end
