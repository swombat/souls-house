class Accounts::IntegrationsController < ApplicationController

  def show
    can_manage_account = current_account.service_credentials_manageable_by?(Current.user)
    service_definitions = Services::Definition.all.select(&:available?).select do |definition|
      definition.supports_management_scope?("personal") ||
        (can_manage_account && definition.supports_management_scope?("account_managed"))
    end
    agents = current_account.agents.by_name.to_a
    connections = current_account.service_connections.account_managed
      .or(current_account.service_connections.personal.where(connected_by_user: Current.user))
      .includes(:connected_by_user).order(:id).to_a
    accesses = AgentServiceAccess
      .where(agent: agents, service_connection: connections)
      .index_by { |access| [ access.agent_id, access.service_connection_id ] }
    repositories = watched_repositories_by_connection(connections)

    render inertia: "accounts/integrations", props: {
      account: current_account.as_json,
      services: service_definitions.map(&:as_json),
      focused_service: service_definitions.find { |definition| definition.key == params[:connect] }&.as_json,
      can_manage_account: can_manage_account,
      connections: connections.map do |connection|
        tailnet_visible = tailnet_visible?(connection)
        json = connection.as_connection_json(current_user: Current.user).merge(
          can_delegate: connection.owner?(Current.user),
          residents: agents.map do |agent|
            access = accesses[[ agent.id, connection.id ]]
            {
              id: agent.to_param,
              name: agent.name,
              active: agent.active?,
              enabled: access&.enabled? || false,
              provisioning_status: access&.provisioning_status,
              access_update_url: account_agent_service_access_path(current_account, agent, connection.public_id),
              # Each granted resident is its own node and joins by its own
              # sign-in; the account screen shows every one of them in one place.
              tailnet_url: (account_agent_tailnet_path(current_account, agent) if tailnet_visible && access&.enabled?),
              integrations_url: (edit_account_agent_path(current_account, agent, tab: "integrations") if tailnet_visible)
            }
          end
        )
        json.merge!(repository_watch_props(connection, repositories.fetch(connection.id, []))) if connection.provider == "github"
        json
      end
    }
  end

  private

  WATCHES_PER_REPOSITORY = 20

  def watched_repositories_by_connection(connections)
    github = connections.select { |connection| connection.provider == "github" }
    return {} if github.empty?

    current_account.watched_repositories.live.where(service_connection: github)
      .includes(:service_connection).order(:full_name).group_by(&:service_connection_id)
  end

  # The GitHub card's Repositories section. Who may connect or disconnect
  # mirrors Accounts::WatchedRepositoriesController; any member may cancel an
  # armed watch (Accounts::RepositoryWatchesController).
  def repository_watch_props(connection, repositories)
    can_manage = connection.provisionable_by?(Current.user) || connection.manageable_by?(Current.user)
    {
      can_manage_repositories: can_manage,
      repositories_url: account_watched_repositories_path(current_account),
      repositories: repositories.map do |repository|
        repository.as_repository_json(include_setup: can_manage).merge(
          url: account_watched_repository_path(current_account, repository),
          watches: recent_watches(repository).map { |watch| watch_props(watch) }
        )
      end
    }
  end

  # Armed watches first, then the latest others.
  def recent_watches(repository)
    repository.repository_watches
      .includes(:chat, :created_by_agent, :created_by_user, :watched_repository)
      .order(Arel.sql("CASE WHEN repository_watches.state = 'armed' THEN 0 ELSE 1 END"), id: :desc)
      .limit(WATCHES_PER_REPOSITORY)
  end

  def watch_props(watch)
    watch.as_watch_json.merge(
      chat_title: watch.chat.title_or_default,
      chat_url: account_chat_path(current_account, watch.chat),
      cancel_url: (account_repository_watch_path(current_account, watch) if watch.armed?)
    )
  end

  # Same rule as Agents::TailnetsController, which the panel calls.
  def tailnet_visible?(connection)
    connection.provider == "tailscale" && connection.status == "connected" &&
      (connection.provisionable_by?(Current.user) || connection.manageable_by?(Current.user))
  end

end
