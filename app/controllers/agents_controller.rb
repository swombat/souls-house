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
      # Directory-only hints must not rebuild cards or claim journal-stat jobs.
      agents: -> { Agents::ResidentDirectory.new(current_account).call },
      can_end_guest_memberships: current_account.owned_by?(Current.user),
      # The reconnect endpoints require the account owner; offer the button to the same people.
      can_manage_provider_subscription: current_account.owned_by?(Current.user),
      guest_memberships: current_account.guest_memberships.includes(agent: :account).order(:created_at).as_json,
      away_memberships: GuestMembership.where(agent: current_account.agents).includes(:account, agent: :account).order(:created_at).as_json,
      guest_candidates: GuestMembership.candidates_for(account: current_account, user: Current.user)
        .includes(:account).by_name.map { |agent| { id: agent.to_param, name: agent.name, home_account_name: agent.account.name } },
      grouped_models: -> { grouped_models },
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
      vm_birth_refusal: Billing::BirthGate.wizard_refusal(current_account) || Agents::VmBirthPolicy.current.refusal(kind: :birth),
      colour_options: Agent::VALID_COLOURS,
      icon_options: Agent::VALID_ICONS,
      ai_api_keys_configured: current_account.ai_api_keys_configured,
      can_manage_ai_credentials: current_account.ai_credentials_manageable_by?(Current.user),
      billing: -> { birth_billing_props },
      account: current_account.as_json
    }
  end

  def create
    attrs = birth_params
    open_beginning = ActiveModel::Type::Boolean.new.cast(attrs.delete(:open_beginning))
    return if birth_provider_key_refused?
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
    interaction_data = nil
    load_interactions = -> {
      interaction_data ||= pagy(:offset, @agent.agent_runtime_interactions.includes(:chat).recent, limit: 25)
    }
    catalog = nil
    load_catalog = -> { catalog ||= @agent.subagent_catalog }
    render inertia: "agents/edit", props: {
      portability: -> { portability_props },
      agent: -> { @agent.as_json },
      house_allowance: -> { HouseInference::Allowance.presentation(@agent) },
      billing_hold: -> { billing_hold_props },
      subagent_catalog: -> { load_catalog.call.options },
      subagent_providers: -> { load_catalog.call.providers },
      subagent_catalog_empty_reason: -> { load_catalog.call.empty_reason },
      subagents_available: -> { @agent.subagents_available? },
      reflexes: -> { reflexes_props },
      # Count/provider partials must not mint another registration token.
      telegram_deep_link: InertiaRails.optional { @agent.telegram_configured? ? @agent.telegram_deep_link_for(Current.user) : nil },
      telegram_configuration: -> { { configured: @agent.telegram_configured?, username: @agent.telegram_bot_username } },
      telegram_subscriber_count: -> { @agent.telegram_subscriptions.active.count },
      telegram_groups: -> { TelegramGroupPresentation.list(@agent, account: current_account) },
      can_manage_telegram_groups: -> { current_account.owned_by?(Current.user) },
      memories: -> { memories_for_display },
      grouped_models: -> { grouped_models },
      colour_options: Agent::VALID_COLOURS,
      icon_options: Agent::VALID_ICONS,
      active_tab: params[:tab],
      local_dev_endpoint_mode: Agents::Config.publish_ports?,
      identity_export_url: identity_export_account_agent_path(current_account, @agent),
      memory_overview_url: account_agent_memory_overview_path(current_account, @agent),
      memory_history_url: Current.user.is_site_admin? ? history_account_agent_memory_overview_path(current_account, @agent) : nil,
      # The Hosting tab is site-admin only; owners get health, Restart and the
      # subscription on Settings.
      can_view_hosting: Current.user.is_site_admin?,
      can_restart_runtime: current_account.owned_by?(Current.user) && @agent.externally_hosted?,
      hosting_diagnostics_url: Current.user.is_site_admin? ? account_agent_hosting_diagnostics_path(current_account, @agent) : nil,
      runtime_observability_url: Current.user&.is_site_admin? ? admin_agent_runtime_path(@agent) : nil,
      sandbox_recreation_url: account_agent_sandbox_recreation_path(current_account, @agent),
      provider_subscription: -> { Agents::ProviderSubscriptionPresentation.call(@agent) },
      hosting_location: -> { Agents::HostingLocation.call(@agent) },
      service_connections: -> { service_connections_for_agent },
      can_manage_provider_subscription: -> { current_account.ai_credentials_manageable_by?(Current.user) },
      interactions: -> { interactions_props(load_interactions.call.last) },
      interactions_pagination: -> { pagy_to_hash(load_interactions.call.first) },
      cost_report: -> { AgentInteractionCostReport.new(agent: @agent).call },
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
    tab ||= "settings" if e.record.errors.attribute_names.include?(:switchable_model_ids)
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

  # Sessions with the reflexes their posts were judged against: the ones
  # offered (name, score, the post) and a count of the rest. Whether the
  # resident then acted on an offer is not recorded, so it is not shown.
  def interactions_props(interactions)
    judgments = Reflex::Judgment.joins(:message)
      .where(messages: { runtime_interaction_id: interactions.map(&:id) })
      .includes(:reflex, message: :chat).order(:id).group_by { |j| j.message.runtime_interaction_id }
    interactions.map do |interaction|
      rows = judgments.fetch(interaction.id, [])
      offered = rows.select(&:offered)
      interaction.as_session_json.merge(
        reflexes: {
          judged_count: rows.size,
          offered: offered.map do |j|
            {
              id: j.to_param, name: j.reflex.name, reminder: j.reflex.reminder, score: j.score,
              message_id: j.message.obfuscated_id, excerpt: j.message.content.to_s.squish.truncate(140),
              created_at: j.created_at&.iso8601
            }
          end
        }
      )
    end
  end

  # The resident's reflexes, read-only: residents write and forget them
  # through conversation (docs/reflexes.md), not through this page. Forgotten
  # ones are included so their history stays visible.
  def reflexes_props
    reflexes = @agent.reflexes.order(:id).to_a
    counts = Reflex::Judgment.where(reflex_id: reflexes.map(&:id)).group(:reflex_id, :offered).count
    last_offered = Reflex::Judgment.where(reflex_id: reflexes.map(&:id), offered: true).group(:reflex_id)
      .maximum(:created_at)
    {
      enabled: ReflexCheck.enabled_for?(@agent),
      max_kept: Reflex::MAX_KEPT,
      items: reflexes.map do |reflex|
        offered = counts.fetch([ reflex.id, true ], 0)
        reflex.as_json.merge(
          judged_count: offered + counts.fetch([ reflex.id, false ], 0),
          offered_count: offered,
          last_offered_at: last_offered[reflex.id]&.iso8601
        )
      end
    }
  end

  # Asleep because its plan lapsed; the Billing tab is where it is paid
  # (shown only to those who can pay).
  def billing_hold_props
    return nil unless @agent.billing_held?

    { billing_url: current_account.owned_by?(Current.user) ? account_billing_path(current_account) : nil }
  end

  # The Plan step, for an account that pays per resident; nil otherwise.
  def birth_billing_props
    return nil unless Billing::BirthGate.requires_plan?(current_account)

    can_pay = current_account.owned_by?(Current.user)
    payment_method, payment_method_error = nil, false
    if can_pay && Billing.configured?
      begin
        payment_method = Billing::PaymentMethod.new(account: current_account).current&.as_json
      rescue Stripe::StripeError => error
        Rails.error.report(error, handled: true, context: { subsystem: "billing" })
        payment_method_error = true
      end
    end
    {
      can_pay: can_pay,
      test_mode: Billing.test_mode?,
      publishable_key: Billing.publishable_key,
      tiers: Billing::Tier.all.select(&:purchasable?).as_json,
      offers: current_account.purchasable_offers.as_json,
      payment_method: payment_method,
      payment_method_error: payment_method_error,
      contact_email: Billing.contact_email,
      card_setup_url: account_billing_card_path(current_account),
      card_setup_complete_url: complete_account_billing_card_path(current_account),
      birth_orders_url: account_birth_orders_path(current_account)
    }
  end

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

  # The "I have my own keys" path on the new-resident page sends the one key
  # the chosen model needs. It is saved to the account like any other model
  # key, before the birth, so the first container already has it.
  def birth_provider_key_refused?
    key = params.fetch(:provider_key, {}).permit(:provider, :value)
    value = key[:value].to_s.strip
    return false if value.blank?

    provider = key[:provider].to_s
    error = if !Account::AI_PROVIDERS.key?(provider.to_sym)
      "Unknown model provider"
    elsif !current_account.ai_credentials_manageable_by?(Current.user)
      "Only account owners and administrators can add model API keys"
    end
    if error
      redirect_to new_account_agent_path(current_account), inertia: { errors: { base: [ error ] } }
      return true
    end

    current_account.update_ai_api_keys!(set: { provider => value })
    audit("update_agent_api_keys", current_account, provider: provider, source: "new_resident")
    false
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
