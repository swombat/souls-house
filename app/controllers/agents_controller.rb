class AgentsController < ApplicationController

  require_feature_enabled :agents
  before_action :set_agent, only: [ :edit, :update, :destroy ]

  def index
    if params[:create].present?
      redirect_to new_account_agent_path(current_account)
      return
    end

    @agents = current_account.agents.by_name

    render inertia: "agents/index", props: {
      agents: @agents.map { |agent|
        agent.as_json.merge(provider_subscription: provider_subscription_for(agent))
      },
      grouped_models: grouped_models,
      available_tools: tools_for_frontend,
      colour_options: Agent::VALID_COLOURS,
      icon_options: Agent::VALID_ICONS,
      account: current_account.as_json
    }
  end

  def new
    render inertia: "agents/new", props: {
      grouped_models: grouped_models,
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
      @agent.agent_runtime_interactions.includes(:chat).recent,
      limit: 25
    )

    render inertia: "agents/edit", props: {
      agent: @agent.as_json,
      telegram_deep_link: @agent.telegram_configured? ? @agent.telegram_deep_link_for(Current.user) : nil,
      telegram_subscriber_count: @agent.telegram_subscriptions.active.count,
      memories: memories_for_display,
      grouped_models: grouped_models,
      available_tools: tools_for_frontend,
      colour_options: Agent::VALID_COLOURS,
      icon_options: Agent::VALID_ICONS,
      active_tab: params[:tab],
      local_dev_endpoint_mode: Agents::Config.publish_ports?,
      identity_export_url: identity_export_account_agent_path(current_account, @agent),
      hosting_diagnostics_url: account_agent_hosting_diagnostics_path(current_account, @agent),
      runtime_observability_url: Current.user&.is_site_admin? ? admin_agent_runtime_path(@agent) : nil,
      sandbox_recreation_url: account_agent_sandbox_recreation_path(current_account, @agent),
      provider_subscription: provider_subscription_for(@agent),
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

    if @agent.update(attrs)
      audit("update_agent", @agent, **agent_audit_data(attrs))
      redirect_to account_agents_path(current_account), notice: update_notice(model_changed)
    else
      redirect_to edit_account_agent_path(current_account, @agent),
                  inertia: { errors: @agent.errors.to_hash }
    end
  end

  def destroy
    audit("destroy_agent", @agent)
    @agent.destroy!
    redirect_to account_agents_path(current_account), notice: "Resident deleted"
  end

  private

  def set_agent
    @agent = current_account.agents.find(params[:id])
  end

  def agent_params
    permitted = params.require(:agent).permit(
      :name, :system_prompt, :reflection_prompt, :memory_reflection_prompt,
      :summary_prompt, :refinement_prompt, :refinement_threshold,
      :model_id, :active, :paused, :colour, :icon,
      :thinking_enabled, :thinking_budget, :reasoning_effort,
      :telegram_bot_token, :telegram_bot_username,
      :voice_id, :persistent_session, :persistent_wake_session, :scheduled_wakes_enabled,
      :heartbeat_wakes_per_day,
      enabled_tools: []
    )

    permitted.delete(:telegram_bot_token) if permitted[:telegram_bot_token].blank?
    strip_externally_managed_params!(permitted) if @agent&.identity_owned_by_agent?
    permitted
  end

  def birth_params
    params.require(:agent).permit(
      :name, :system_prompt, :model_id, :colour, :icon,
      :scheduled_wakes_enabled, :open_beginning
    )
  end

  def strip_externally_managed_params!(permitted)
    Agent::EXTERNALLY_MANAGED_ATTRIBUTES.each do |attribute|
      permitted.delete(attribute)
    end
  end

  def agent_audit_data(attrs)
    attrs.except(:telegram_bot_token).to_h
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
    Chat::MODELS.group_by { |m| m[:group] || "Other" }.transform_values do |models|
      models.map do |m|
        reasoning = Chat.reasoning_effort_config(m[:model_id])
        {
          model_id: m[:model_id],
          label: m[:label],
          supports_thinking: m.dig(:thinking, :supported) == true,
          reasoning:
        }
      end
    end
  end

  def tools_for_frontend
    Agent.available_tools.map do |tool|
      {
        class_name: tool.name,
        name: tool.name.underscore.humanize.sub(/ tool$/i, ""),
        description: tool.try(:description)
      }
    end
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

  def provider_subscription_for(agent)
    return unless agent.externally_hosted?

    provider = Agents::Sandbox.subscription_provider_for(agent)
    return unless provider

    {
      id: agent.to_param,
      name: agent.name,
      provider: provider,
      provider_name: {
        "anthropic" => "Claude",
        "gemini" => "Google AI",
        "openai" => "ChatGPT",
        "xai" => "xAI"
      }.fetch(provider),
      runtime: agent.runtime,
      available: agent.external? && agent.health_state == "healthy",
      auth_mode: agent.provider_auth_mode(provider),
      connection: agent.provider_connection(provider)
    }
  rescue KeyError
    nil
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
          access_update_url: account_agent_service_access_path(current_account, @agent, connection.public_id)
        )
      end
  end

end
