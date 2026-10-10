module Api
  module V1
    # Repository watches: "when this finishes, post the result in that
    # conversation and wake me once". See RepositoryWatch.
    class WatchesController < BaseController

      # GET /api/v1/watches[?repository=owner/name][&state=armed]
      def index
        scope = visible_watches.includes(:watched_repository, :chat, :created_by_agent, :created_by_user).order(id: :desc)
        scope = scope.where(watched_repository: find_repository) if params[:repository].present? || params[:repository_id].present?
        scope = scope.where(state: params[:state].to_s) if params[:state].present?
        render json: { watches: scope.limit(100).map(&:as_watch_json) }
      end

      def show
        render json: { watch: visible_watches.find(params[:id]).as_watch_json }
      end

      # POST /api/v1/watches
      def create
        repository = find_repository
        chat = actionable_chats.find(params.require(:chat_id))
        watch = RepositoryWatch.arm!(
          repository: repository,
          chat: chat,
          by: current_api_agent || current_api_user,
          event_kind: params.require(:event).to_s,
          filter: {
            "head_sha" => params[:sha],
            "workflow_name" => params[:workflow],
            "environment" => params[:environment],
            "conclusions" => params[:conclusions],
            "states" => params[:states]
          },
          wake: ActiveModel::Type::Boolean.new.cast(params[:wake]) || false,
          expires_in: params[:expires_in]
        )
        render json: { watch: watch.as_watch_json }, status: :created
      rescue RepositoryWatch::Refused => error
        render json: { error: error.message }, status: error.status
      rescue ActionController::ParameterMissing => error
        render json: { error: "#{error.param} is required" }, status: :unprocessable_entity
      end

      # DELETE /api/v1/watches/:id — the resident that armed it, or a member
      # of the account.
      def destroy
        watch = visible_watches.find(params[:id])
        watch.cancel!(reason: "cancelled by #{current_api_agent ? current_api_agent.name : 'a member'}")
        render json: { watch: watch.reload.as_watch_json }
      end

      private

      def visible_watches
        return RepositoryWatch.where(created_by_agent_id: current_api_agent.id) if current_api_agent

        RepositoryWatch.where(account_id: human_account!.id)
      end

      # By owner/name or id, among the repositories this caller may watch.
      def find_repository
        scope = WatchedRepository.live.where(account_id: current_api_agent ? current_api_account.id : human_account!.id)
        if params[:repository_id].present?
          scope.find(params[:repository_id])
        else
          scope.where("lower(full_name) = ?", params.require(:repository).to_s.downcase).first!
        end
      end

    end
  end
end
