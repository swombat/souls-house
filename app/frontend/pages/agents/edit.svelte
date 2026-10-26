<script>
  import AgentHostingPanel from '$lib/components/agents/agent-hosting-panel.svelte';
  import AgentRuntimeStatus from '$lib/components/agents/AgentRuntimeStatus.svelte';
  import AgentSubscriptionSettings from '$lib/components/agents/AgentSubscriptionSettings.svelte';
  import { useForm, router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import {
    Palette,
    Gear,
    UsersThree,
    Plug,
    CloudArrowUp,
    TerminalWindow,
    CurrencyDollar,
    Graph,
    Lightning,
  } from 'phosphor-svelte';
  import {
    accountAgentsPath,
    accountAgentPath,
    accountAgentTelegramTestPath,
    accountAgentTelegramWebhookPath,
  } from '@/routes';
  import { useSync, createDynamicSync } from '$lib/use-sync';

  import AgentAppearancePanel from '$lib/components/agents/AgentAppearancePanel.svelte';
  import AgentEditHeader from '$lib/components/agents/AgentEditHeader.svelte';
  import AsleepBanner from '$lib/components/agents/AsleepBanner.svelte';
  import AgentIntegrationsPanel from '$lib/components/agents/AgentIntegrationsPanel.svelte';
  import ResidentMemoryPanel from '$lib/components/agents/ResidentMemoryPanel.svelte';
  import AgentSettingsPanel from '$lib/components/agents/AgentSettingsPanel.svelte';
  import AgentSubagentsPanel from '$lib/components/agents/AgentSubagentsPanel.svelte';
  import AgentSettingsTabs from '$lib/components/agents/AgentSettingsTabs.svelte';
  import AgentInteractionsPanel from '$lib/components/agents/AgentInteractionsPanel.svelte';
  import AgentCostsPanel from '$lib/components/agents/AgentCostsPanel.svelte';
  import AgentReflexesPanel from '$lib/components/agents/AgentReflexesPanel.svelte';
  import ResidentPortabilityPanel from '$lib/components/agents/resident-portability-panel.svelte';

  let {
    agent,
    house_allowance: houseAllowance = null,
    billing_hold: billingHold = null,
    telegram_configuration: telegramConfiguration = null,
    telegram_subscriber_count: telegramSubscriberCount = 0,
    grouped_models = {},
    colour_options = [],
    icon_options = [],
    active_tab: activeTabProp = null,
    local_dev_endpoint_mode: localDevEndpointMode = false,
    identity_export_url: identityExportUrl = null,
    memory_overview_url: memoryOverviewUrl = null,
    memory_history_url: memoryHistoryUrl = null,
    hosting_diagnostics_url: hostingDiagnosticsUrl = null,
    can_view_hosting: canViewHosting = false,
    can_restart_runtime: canRestartRuntime = false,
    runtime_observability_url: runtimeObservabilityUrl = null,
    sandbox_recreation_url: sandboxRecreationUrl = null,
    provider_subscription: providerSubscription = null,
    service_connections: serviceConnections = [],
    can_manage_provider_subscription: canManageProviderSubscription = false,
    interactions = [],
    interactions_pagination: interactionsPagination = {},
    cost_report: costReport = {},
    portability = null,
    subagent_catalog = [],
    subagent_catalog_empty_reason = null,
    subagent_providers = [],
    subagents_available: subagentsAvailable = false,
    reflexes = {},
    account,
  } = $props();

  useSync({
    [`Agent:${agent.id}`]: [
      'agent',
      'memories',
      'interactions',
      'interactions_pagination',
      'cost_report',
      'reflexes',
      'subagents_available',
    ],
  });

  const updateIntegrationSync = createDynamicSync();
  $effect(() => {
    updateIntegrationSync({ [`IntegrationStatus:${account.id}`]: ['service_connections'] });
  });
  const updateProviderSync = createDynamicSync();
  $effect(() => {
    updateProviderSync({
      [`ProviderPresentation:${account.id}`]: ['provider_subscription', 'can_manage_provider_subscription'],
    });
  });
  const updateTelegramSync = createDynamicSync();
  $effect(() => {
    updateTelegramSync({
      [`TelegramPresentation:${agent.id}`]: ['telegram_configuration', 'telegram_subscriber_count'],
    });
  });

  let selectedModel = $state(agent.model_id);
  let sendingTestNotification = $state(false);
  let registeringWebhook = $state(false);
  // Hosting is site-admin only; old ?tab=hosting links land on Settings,
  // where the subscription now lives.
  let activeTab = $state(
    activeTabProp === 'identity'
      ? 'appearance'
      : activeTabProp === 'model' || (activeTabProp === 'hosting' && !canViewHosting)
        ? 'settings'
        : activeTabProp || 'appearance'
  );
  let runtimeManaged = $derived(
    Boolean(agent.birth_committed_at) || agent.runtime === 'external' || agent.runtime === 'offline'
  );
  let showFormActions = $derived(
    activeTab !== 'memory' &&
      activeTab !== 'portability' &&
      activeTab !== 'interactions' &&
      activeTab !== 'costs' &&
      activeTab !== 'reflexes' &&
      activeTab !== 'integrations' &&
      (!runtimeManaged ||
        activeTab === 'appearance' ||
        activeTab === 'settings' ||
        activeTab === 'subagents' ||
        activeTab === 'hosting')
  );
  let hostingVisited = $state(false);
  $effect(() => {
    if (activeTab === 'hosting') hostingVisited = true;
  });

  // Sub-agents come with the Work plan and with residents on the house; on
  // lower plans the tab is hidden and the server ignores the switch.
  let showSubagents = $derived(Boolean(subagentsAvailable));
  let tabs = $derived([
    { id: 'appearance', label: 'Appearance', icon: Palette },
    { id: 'settings', label: 'Settings', icon: Gear },
    ...(showSubagents ? [{ id: 'subagents', label: 'Sub-agents', icon: UsersThree }] : []),
    { id: 'integrations', label: 'Integrations', icon: Plug },
    ...(canViewHosting ? [{ id: 'hosting', label: 'Hosting', icon: CloudArrowUp }] : []),
    { id: 'interactions', label: 'Sessions', icon: TerminalWindow },
    { id: 'reflexes', label: 'Reflexes', icon: Lightning },
    { id: 'memory', label: 'Memory', icon: Graph },
    { id: 'costs', label: 'Costs', icon: CurrencyDollar },
    ...(portability?.can_manage ? [{ id: 'portability', label: 'Export / Import', icon: CloudArrowUp }] : []),
  ]);

  let form = useForm({
    agent: {
      name: agent.name,
      model_id: agent.model_id,
      active: agent.active,
      paused: agent.paused || false,
      colour: agent.colour || null,
      icon: agent.icon || null,
      thinking_enabled: agent.thinking_enabled || false,
      thinking_budget: agent.thinking_budget || 10000,
      reasoning_effort: agent.reasoning_effort || 'default',
      telegram_bot_username: agent.telegram_bot_username || '',
      telegram_bot_token: agent.telegram_bot_token || '',
      persistent_session: agent.persistent_session || false,
      persistent_wake_session: agent.persistent_wake_session || false,
      scheduled_wakes_enabled: agent.scheduled_wakes_enabled ?? true,
      heartbeat_wakes_per_day: agent.heartbeat_wakes_per_day ?? 2,
      session_idle_timeout_minutes: agent.session_idle_timeout_minutes ?? 45,
      session_max_age_minutes: agent.session_max_age_minutes ?? 240,
      session_context_budget_tokens: agent.session_context_budget_tokens ?? 300000,
      turn_timeout_minutes: agent.turn_timeout_minutes ?? 30,
      subagents_enabled: agent.subagents_enabled || false,
      subagent_models: agent.subagent_models || [],
      switchable_model_ids: agent.switchable_model_ids || [],
      resident_may_switch_model: agent.resident_may_switch_model || false,
    },
  });

  function updateAgent() {
    $form.agent.model_id = selectedModel;
    $form.patch(accountAgentPath(account.id, agent.id));
  }

  function sendTestNotification() {
    sendingTestNotification = true;
    router.post(
      accountAgentTelegramTestPath(account.id, agent.id),
      {},
      {
        preserveScroll: true,
        onFinish() {
          sendingTestNotification = false;
        },
      }
    );
  }

  function registerWebhook() {
    registeringWebhook = true;
    router.post(
      accountAgentTelegramWebhookPath(account.id, agent.id),
      {},
      {
        preserveScroll: true,
        onFinish() {
          registeringWebhook = false;
        },
      }
    );
  }
</script>

<svelte:head>
  <title>Edit {agent.name}</title>
</svelte:head>

<div class="p-8 max-w-5xl mx-auto">
  <AgentEditHeader backHref={accountAgentsPath(account.id)} agentName={agent.name} />
  {#if billingHold}<AsleepBanner name={agent.name} billingUrl={billingHold.billing_url} />{/if}

  <form
    onsubmit={(e) => {
      e.preventDefault();
      updateAgent();
    }}>
    <div class="flex flex-col md:flex-row gap-6 md:gap-8">
      <AgentSettingsTabs {tabs} bind:activeTab />

      <!-- Content area -->
      <div class="flex-1 min-w-0 space-y-6">
        {#if hostingVisited && canViewHosting}
          <div hidden={activeTab !== 'hosting'}>
            <AgentHostingPanel
              {agent}
              {account}
              {runtimeManaged}
              {sandboxRecreationUrl}
              {identityExportUrl}
              {hostingDiagnosticsUrl} />
          </div>
        {/if}

        {#if activeTab === 'appearance'}
          <AgentAppearancePanel
            bind:name={$form.agent.name}
            bind:colour={$form.agent.colour}
            bind:icon={$form.agent.icon}
            nameError={$form.errors.name}
            colourOptions={colour_options}
            iconOptions={icon_options} />
        {:else if activeTab === 'settings'}
          <AgentRuntimeStatus {agent} {sandboxRecreationUrl} canRestart={canRestartRuntime} />
          <AgentSettingsPanel
            {houseAllowance}
            {form}
            groupedModels={grouped_models}
            {runtimeManaged}
            bind:selectedModel>
            {#snippet subscription()}
              {#if providerSubscription}
                <AgentSubscriptionSettings {account} {providerSubscription} {canManageProviderSubscription} />
              {/if}
            {/snippet}
          </AgentSettingsPanel>
        {:else if activeTab === 'subagents' && showSubagents}
          <AgentSubagentsPanel
            bind:enabled={$form.agent.subagents_enabled}
            bind:models={$form.agent.subagent_models}
            catalog={subagent_catalog}
            emptyReason={subagent_catalog_empty_reason}
            providers={subagent_providers}
            serverErrors={[$form.errors.subagent_models, $form.errors.subagents_enabled].flat().filter(Boolean)} />
        {:else if activeTab === 'integrations'}
          <AgentIntegrationsPanel
            {form}
            {agent}
            {account}
            {telegramConfiguration}
            {telegramSubscriberCount}
            {sendingTestNotification}
            {registeringWebhook}
            {serviceConnections}
            onsendTestNotification={sendTestNotification}
            onregisterWebhook={registerWebhook} />
        {:else if activeTab === 'memory'}
          <ResidentMemoryPanel overviewUrl={memoryOverviewUrl} historyUrl={memoryHistoryUrl} />
        {:else if activeTab === 'interactions'}
          <AgentInteractionsPanel
            {interactions}
            pagination={interactionsPagination}
            {account}
            {agent}
            {runtimeObservabilityUrl} />
        {:else if activeTab === 'reflexes'}
          <AgentReflexesPanel {reflexes} agentName={agent.name} />
        {:else if activeTab === 'costs'}
          <AgentCostsPanel report={costReport} />
        {:else if activeTab === 'portability'}
          <ResidentPortabilityPanel {portability} />
        {/if}

        {#if showFormActions}
          <div class="flex justify-end gap-3">
            <a href={accountAgentsPath(account.id)}>
              <Button type="button" variant="outline">Cancel</Button>
            </a>
            <Button type="submit" disabled={$form.processing}>
              {$form.processing ? 'Saving...' : 'Update Resident'}
            </Button>
          </div>
        {/if}
      </div>
    </div>
  </form>
</div>
