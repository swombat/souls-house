module Api
  module V1
    # Repositories connected for watches. A resident sees the ones on GitHub
    # connections it holds a grant for; a person sees the account's. Only a
    # person connects or disconnects one.
    class RepositoriesController < BaseController

      before_action :require_human_actor!, only: %i[create destroy]

      # GET /api/v1/repositories
      def index
        render json: { repositories: visible_repositories.order(:full_name).map { |repository| repository_json(repository) } }
      end

      # POST /api/v1/repositories {full_name, service_connection_id?}
      def create
        account = human_account!
        connection = github_connection(account)
        return if performed?

        repository = WatchedRepository.connect!(connection: connection, full_name: params[:full_name].to_s, user: current_api_user)
        audit_human_action("repository_watch.connect", repository, account: account, full_name: repository.full_name)
        render json: { repository: repository_json(repository) }, status: :created
      rescue WatchedRepository::ConnectError => error
        render json: { error: error.message }, status: :unprocessable_entity
      end

      # DELETE /api/v1/repositories/:id
      def destroy
        account = human_account!
        repository = account.watched_repositories.live.find(params[:id])
        repository.remove!(reason: "repository disconnected")
        audit_human_action("repository_watch.disconnect", repository, account: account, full_name: repository.full_name)
        head :no_content
      end

      private

      def visible_repositories
        scope = WatchedRepository.live.where(account_id: current_api_account.id)
        return scope.where(account_id: human_account!.id) unless current_api_agent

        scope.where(service_connection_id: AgentServiceAccess.enabled.where(agent: current_api_agent).select(:service_connection_id))
      end

      def repository_json(repository)
        include_setup = !current_api_agent && repository.service_connection.manageable_by?(current_api_user)
        repository.as_repository_json(include_setup: include_setup)
      end

      # The named connection, or the account's only usable GitHub connection.
      def github_connection(account)
        usable = account.service_connections.where(provider: "github", status: "connected").to_a
          .select { |connection| connection.provisionable_by?(current_api_user) || connection.manageable_by?(current_api_user) }
        if params[:service_connection_id].present?
          connection = usable.find { |candidate| candidate.public_id == params[:service_connection_id].to_s }
          return connection if connection

          render json: { error: "GitHub connection not found" }, status: :not_found
        elsif usable.one?
          usable.first
        elsif usable.empty?
          render json: { error: "Connect GitHub under Integrations first" }, status: :unprocessable_entity
        else
          render json: { error: "Several GitHub connections; pass service_connection_id", connections: usable.map(&:public_id) }, status: :unprocessable_entity
        end
      end

    end
  end
end
