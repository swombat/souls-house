class AgentsController < ApplicationController

  include AgentSettingsParams

  require_feature_enabled :agents
  before_action :set_agent, only: [ :edit, :update, :destroy ]

  def index
    if params[:create].present?
      redirect_to new_account_agent_path(current_account)
      return
    end

    render inertia: "agents/index", props: {
      resident_import_url: current_account.owned_by?(Current.user) ? import_account_agents_path(current_account) : nil,
      github_resident_import_url: GithubResidentImport.requestable_by?(current_account, Current.user) ? new_account_github_resident_import_path(current_account) : nil,
      agents: Agents::ResidentDirectory.new(current_account).call,
      can_end_guest_memberships: current_account.owned_by?(Current.user),
      guest_memberships: current_account.guest_memberships.includes(agent: :account).order(:created_at).as_json,
      away_memberships: GuestMembership.where(agent: current_account.agents).includes(:account, agent: :account).order(:created_at).as_json,
      guest_candidates: GuestMembership.candidates_for(account: current_account, user: Current.user)
        .includes(:account).by_name.map { |agent| { id: agent.to_param, name: agent.name, home_account_name: agent.account.name } },
      grouped_models: grouped_models,
      colour_options: Agent::VALID_COLOURS,
      icon_options: Agent::VALID_ICONS,
      account: current_account.as_json
    }
  end

  def new
    render inertia: "agents/new", props: {
      grouped_models: grouped_models,
      resident_import_url: current_account.owned_by?(Current.user) ? import_account_agents_path(current_account) : nil,
      github_resident_import_url: GithubResidentImport.requestable_by?(current_account, Current.user) ? new_account_github_resident_import_path(current_account) : nil,
      default_model_id: Agents::HostedBirth.default_model_id(account: current_account, creator: Current.user),
      colour_options: Agent::VALID_COLOURS,
      icon_options: Agent::VALID_ICONS,
      account: current_account.as_json
    }
  end

  def create
    attrs = birth_params
    open_beginning = ActiveModel::Type::Boolean.new.cast(attrs.delete(:open_beginning))
    @agent = Agents::HostedBirth.new(
      account: current_account,
      creator: Current.user,
      attributes: attrs,
      open_beginning: open_beginning
    ).create!
    audit("create_agent", @agent, **agent_audit_data(attrs))
    redirect_to onboarding_account_agent_path(current_account, @agent), notice: "#{@agent.name} is being prepared"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to new_account_agent_path(current_account),
                inertia: { errors: e.record.errors.to_hash }
  rescue Agents::HostedProvisioning::ConfigurationError => e
    redirect_to new_account_agent_path(current_account),
                inertia: { errors: { base: [ e.message ] } }
  end

  def edit
    interactions_pagy, interactions = pagy(
      :offset,
      @agent.agent_runtime_interactions.includes(:chat).recent,
      limit: 25
    )

    catalog = @agent.subagent_catalog
    render inertia: "agents/edit", props: {
      portability: portability_props,
      agent: @agent.as_json,
      house_allowance: HouseInferenceGrant.find_by(agent: @agent)&.presentation,
      subagent_catalog: catalog.options,
      subagent_providers: catalog.providers,
      subagent_catalog_empty_reason: catalog.empty_reason,
      telegram_deep_link: @agent.telegram_configured? ? @agent.telegram_deep_link_for(Current.user) : nil,
      telegram_subscriber_count: @agent.telegram_subscriptions.active.count,
      memories: memories_for_display,
      grouped_models: grouped_models,
      colour_options: Agent::VALID_COLOURS,
      icon_options: Agent::VALID_ICONS,
      active_tab: params[:tab],
      local_dev_endpoint_mode: Agents::Config.publish_ports?,
      identity_export_url: identity_export_account_agent_path(current_account, @agent),
      memory_overview_url: account_agent_memory_overview_path(current_account, @agent),
      memory_history_url: Current.user.is_site_admin? ? history_account_agent_memory_overview_path(current_account, @agent) : nil,
      hosting_diagnostics_url: account_agent_hosting_diagnostics_path(current_account, @agent),
      runtime_observability_url: Current.user&.is_site_admin? ? admin_agent_runtime_path(@agent) : nil,
      sandbox_recreation_url: account_agent_sandbox_recreation_path(current_account, @agent),
      provider_subscription: Agents::ProviderSubscriptionPresentation.call(@agent),
      service_connections: service_connections_for_agent,
      can_manage_provider_subscription: current_account.ai_credentials_manageable_by?(Current.user),
      interactions: interactions.map(&:as_session_json),
      interactions_pagination: pagy_to_hash(interactions_pagy),
      cost_report: AgentInteractionCostReport.new(agent: @agent).call,
      account: current_account.as_json
    }
  end

  def update
    attrs = agent_params
    model_changed = attrs.key?(:model_id) && attrs[:model_id] != @agent.model_id

    @agent.update_settings!(attrs, by: Current.user)
    audit("update_agent", @agent, **agent_audit_data(attrs))
    redirect_to account_agents_path(current_account), notice: update_notice(model_changed)
  rescue ActiveRecord::RecordInvalid => e
    tab = "subagents" if e.record.errors.attribute_names.intersect?(%i[subagents_enabled subagent_models])
    redirect_to edit_account_agent_path(current_account, @agent, tab: tab),
                inertia: { errors: e.record.errors.to_hash }
  end

  def destroy
    # Retain the DELETE route for old clients, but never destroy a resident here.
    # Keep scheduling preferences, identity, memory and history for re-enabling.
    @agent.update!(active: false)
    audit("disable_agent", @agent)
    redirect_to account_agents_path(current_account), notice: "Resident disabled. Their history and files are preserved."
  end

  private

  def portability_props
    can_manage = current_account.owned_by?(Current.user)
    supported = @agent.externally_hosted? && !@agent.imported_home?
    reason = Agents::Portability::Export.unavailable_reason(@agent)
    if can_manage && !reason
      begin
        Agents::Portability::Transport.new(@agent).stopped!
      rescue Agents::Portability::Error, Agents::Resources::OwnershipError
        reason = "Stop the resident before export; runtime state must be verifiable"
      end
    end
    { can_manage: can_manage, export_url: portable_export_account_agent_path(current_account, @agent),
      import_url: import_account_agents_path(current_account),
      stop_url: supported ? portability_stop_account_agent_path(current_account, @agent) : nil,
      activate_url: supported && !@agent.active? && @agent.paused? ? portability_activate_account_agent_path(current_account, @agent) : nil,
      imported: @agent.portability_custody.present?, export_ready: can_manage && reason.nil?, unavailable_reason: reason }
  end

  def set_agent
    @agent = current_account.agents.find(params[:id])
  end

  def update_notice(model_changed)
    return "Resident updated" unless model_changed && @agent.identity_owned_by_agent?

    expiry = 7.days.from_now.to_date.strftime("%-d %B")
    message = "#{@agent.name} was updated. An account-wide notice will stand until #{expiry}."
    if @agent.external? && @agent.health_state == "healthy"
      "#{message} souls.house has requested a fresh orientation on the new model."
    else
      "#{message} The resident will see the notice on their next activation."
    end
  end

  def grouped_models
    Agents::ModelCatalogue.grouped
  end

  def memories_for_display
    scope = @agent.memories.where(memory_type: :core)
      .or(@agent.memories.where(memory_type: :journal, created_at: AgentMemory::JOURNAL_WINDOW.ago..))
    scope.recent_first.map do |m|
      {
        id: m.id,
        content: m.content,
        memory_type: m.memory_type,
        constitutional: m.constitutional?,
        discarded: m.discarded?,
        created_at: m.created_at.strftime("%Y-%m-%d %H:%M"),
        expired: m.expired?,
        age_in_days: ((Time.current - m.created_at) / 1.day).floor
      }
    end
  end

  def service_connections_for_agent
    accesses = @agent.agent_service_accesses.index_by(&:service_connection_id)
    current_account.service_connections
      .connected
      .includes(:connected_by_user)
      .map do |connection|
        access = accesses[connection.id]
        connection.as_connection_json(current_user: Current.user).merge(
          enabled: access&.enabled? || false,
          provisioning_status: access&.provisioning_status,
          access_update_url: account_agent_service_access_path(current_account, @agent, connection.public_id),
          tailnet_url: connection.provider == "tailscale" ? account_agent_tailnet_path(current_account, @agent) : nil
        )
      end
  end

end
