# The JSON an integration card is drawn from: the connection, the residents
# who can be switched on for it (hosted and guest), and the per-provider
# extras. Shared by the Integrations page and the access step a new
# connection lands on (Accounts::ServiceConnectionAccessesController).
module IntegrationConnectionProps

  extend ActiveSupport::Concern

  private

  # Where a freshly made connection should land: the access step while no
  # resident can use it and there is someone to switch on; otherwise the
  # Integrations page. "Can use" is effective access, as on the card: a
  # guest still awaiting its home's approval is nobody yet.
  def after_connect_path(connection, fallback)
    account = connection.account
    return fallback unless connection.status == "connected"
    return fallback if connection.agent_service_accesses.effective.exists?
    return fallback unless account.agents.exists? || account.guest_agents.exists?

    account_service_connection_access_path(account, connection.public_id)
  end

  def integration_connections_json(connections, agents:, guests:)
    accesses = AgentServiceAccess
      .where(agent: agents + guests, service_connection: connections)
      .includes(:home_approval_by)
      .index_by { |access| [ access.agent_id, access.service_connection_id ] }
    repositories = watched_repositories_by_connection(connections)
    connections.map do |connection|
      integration_connection_json(connection, agents: agents, guests: guests, accesses: accesses,
                                  repositories: repositories.fetch(connection.id, []))
    end
  end

  def integration_connection_json(connection, agents:, guests:, accesses:, repositories:)
    tailnet_visible = tailnet_visible?(connection)
    # Sending as the owner (comms): offered only where sending is
    # switched on for the provider, and granted by the owner alone.
    sendable = CommsSending.available_for?(connection)
    json = connection.as_connection_json(current_user: Current.user).merge(
      can_delegate: connection.owner?(Current.user),
      residents: agents.filter_map do |agent|
        access = accesses[[ agent.id, connection.id ]]
        next unless agent.offered_for_sharing?(granted: access&.enabled? || false)

        resident = {
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
        if sendable
          resident[:can_send] = access&.can_send? || false
          resident[:send_grant_url] = account_agent_service_access_send_grant_path(current_account, agent, connection.public_id)
        end
        resident
      end + guests.filter_map do |agent|
        access = accesses[[ agent.id, connection.id ]]
        next unless agent.offered_for_sharing?(granted: access&.enabled? || false)

        resident = {
          id: agent.to_param,
          name: agent.name,
          active: agent.active?,
          guest: true,
          home_account_name: agent.account.name,
          enabled: access&.enabled? || false,
          effective: access&.effective? || false,
          provisioning_status: access&.provisioning_status,
          access_update_url: account_agent_service_access_path(current_account, agent, connection.public_id),
          can_share: connection.guest_access_changeable_by?(Current.user, enabled: true),
          can_withdraw: connection.guest_access_changeable_by?(Current.user, enabled: false)
        }
        resident.merge!(access.home_approval_json) if access
        if sendable
          resident[:can_send] = access&.can_send? || false
          resident[:send_grant_url] = account_agent_service_access_send_grant_path(current_account, agent, connection.public_id)
        end
        resident
      end
    )
    json[:can_grant_send] = connection.owner?(Current.user) if sendable
    if comms_sends_visible?(connection, sendable)
      json[:comms_sends_url] = account_service_connection_comms_sends_path(current_account, connection.public_id)
    end
    json.merge!(repository_watch_props(connection, repositories)) if connection.provider == "github"
    json
  end

  # The owner's record of sends and grants: wherever sending is on, and
  # wherever there is history to read even if it has since been switched off.
  def comms_sends_visible?(connection, sendable)
    return false unless connection.credential_strategy == "connector" && connection.owner?(Current.user)

    sendable || connection.comms_send_grant_events.exists?
  end

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
