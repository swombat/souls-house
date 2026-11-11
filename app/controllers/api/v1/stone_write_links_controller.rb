module Api
  module V1
    # A stone's write link: POST makes one (or replaces it, so the old link
    # stops working), DELETE revokes it. Whoever holds the link can add rows
    # to the tables the stone reads; the stone's plain link stays read-only.
    class StoneWriteLinksController < BaseController

      before_action :set_stone

      def create
        raise ActiveRecord::RecordNotFound if @stone.withdrawn?
        unless @stone.latest_revision&.interactive? && @stone.latest_revision.field_tables.kept.exists?
          return render json: { error: "Only an interactive stone that reads Field tables can have a write link" },
            status: :unprocessable_entity
        end

        @stone.issue_write_key!
        render json: { stone: { id: @stone.to_param, public_url: @stone.public_url, **@stone.write_json } }, status: :created
      end

      def destroy
        @stone.revoke_write_key!
        head :no_content
      end

      private

      def set_stone
        response.headers["Cache-Control"] = "no-store"
        scope = (current_api_agent ? current_api_account.chats : human_chats).kept
        if current_api_agent
          scope = scope.joins(:chat_agents).where(chat_agents: { agent_id: current_api_agent.id })
        end
        @stone = scope.find(params[:conversation_id]).stones.find(params[:stone_id])
      end

    end
  end
end
