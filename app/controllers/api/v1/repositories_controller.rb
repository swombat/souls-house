module Api
  module V1
    # Repositories connected for watches. A resident sees, connects and
    # disconnects through the GitHub connections it holds an enabled grant
    # for; a person through the account's connections they can manage. GitHub
    # decides whether the connection's token may install the hook: when it
    # refuses, the repository is left for manual setup, and only a person who
    # can manage the connection sees the secret.
    class RepositoriesController < BaseController

      # GET /api/v1/repositories
      def index
        render json: { repositories: visible_repositories.order(:full_name).map { |repository| repository_json(repository) } }
      end

      # POST /api/v1/repositories {full_name, service_connection_id?}
      def create
        account, usable = connect_scope
        connection = github_connection(usable)
        return if performed?

        repository = WatchedRepository.connect!(connection: connection, full_name: params[:full_name].to_s, by: current_api_agent || current_api_user)
        audit_repository_action("repository_watch.connect", repository, account: account)
        render json: { repository: repository_json(repository) }, status: :created
      rescue WatchedRepository::ConnectError => error
        render json: { error: error.message }, status: :unprocessable_entity
      end

      # DELETE /api/v1/repositories/:id: a person who can manage the
      # connection, or the resident that connected it (still granted). A
      # resident never removes a repository someone else connected, since
      # that cancels their watches.
      def destroy
        account, usable = connect_scope
        repository = account.watched_repositories.live.find(params[:id])
        unless usable.include?(repository.service_connection) && (!current_api_agent || repository.created_by_agent_id == current_api_agent.id)
          return render json: { error: disconnect_refusal }, status: :forbidden
        end

        repository.remove!(reason: "repository disconnected")
        audit_repository_action("repository_watch.disconnect", repository, account: account)
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

      # The account acted in, and the GitHub connections the caller may
      # connect through there: a resident's granted ones in its own account,
      # or the ones a person can manage or provision.
      def connect_scope
        if current_api_agent
          account = current_api_agent.account
          granted = AgentServiceAccess.enabled.where(agent: current_api_agent).select(:service_connection_id)
          [ account, account.service_connections.where(provider: "github", status: "connected", id: granted).to_a ]
        else
          account = human_account!
          usable = account.service_connections.where(provider: "github", status: "connected").to_a
            .select { |connection| connection.provisionable_by?(current_api_user) || connection.manageable_by?(current_api_user) }
          [ account, usable ]
        end
      end

      def disconnect_refusal
        return "A resident disconnects only repositories it connected, while it holds a grant on their GitHub connection" if current_api_agent

        "Only someone who can manage the GitHub connection can disconnect its repositories"
      end

      # The named connection, or the caller's only usable GitHub connection.
      def github_connection(usable)
        if params[:service_connection_id].present?
          connection = usable.find { |candidate| candidate.public_id == params[:service_connection_id].to_s }
          return connection if connection

          render json: { error: "GitHub connection not found" }, status: :not_found
        elsif usable.one?
          usable.first
        elsif usable.empty?
          message = current_api_agent ? "No GitHub connection is granted to you; ask a member to grant one under Integrations" : "Connect GitHub under Integrations first"
          render json: { error: message }, status: current_api_agent ? :forbidden : :unprocessable_entity
        else
          render json: { error: "Several GitHub connections; pass service_connection_id", connections: usable.map(&:public_id) }, status: :unprocessable_entity
        end
      end

      def audit_repository_action(action, repository, account:)
        if current_api_agent
          AuditLog.create!(
            user: current_api_user,
            account: account,
            action: action,
            auditable: repository,
            data: { full_name: repository.full_name, agent_id: current_api_agent.id, actor: "resident" },
            ip_address: request.remote_ip,
            user_agent: request.user_agent
          )
        else
          audit_human_action(action, repository, account: account, full_name: repository.full_name)
        end
      end

    end
  end
end
