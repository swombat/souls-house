<script>
  import AgentHostingPanel from '$lib/components/agents/agent-hosting-panel.svelte';
  import { useForm, router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Palette, Gear, Plug, CloudArrowUp, TerminalWindow, CurrencyDollar, Graph } from 'phosphor-svelte';
  import {
    accountAgentsPath,
    accountAgentPath,
    accountAgentTelegramTestPath,
    accountAgentTelegramWebhookPath,
  } from '@/routes';
  import { useSync } from '$lib/use-sync';

  import AgentAppearancePanel from '$lib/components/agents/AgentAppearancePanel.svelte';
  import AgentEditHeader from '$lib/components/agents/AgentEditHeader.svelte';
  import AgentIntegrationsPanel from '$lib/components/agents/AgentIntegrationsPanel.svelte';
  import ResidentMemoryPanel from '$lib/components/agents/ResidentMemoryPanel.svelte';
  import AgentSettingsPanel from '$lib/components/agents/AgentSettingsPanel.svelte';
  import AgentSettingsTabs from '$lib/components/agents/AgentSettingsTabs.svelte';
  import AgentInteractionsPanel from '$lib/components/agents/AgentInteractionsPanel.svelte';
  import AgentCostsPanel from '$lib/components/agents/AgentCostsPanel.svelte';

  let {
    agent,
    house_allowance: houseAllowance = null,
    telegram_deep_link: telegramDeepLink = null,
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
    runtime_observability_url: runtimeObservabilityUrl = null,
    sandbox_recreation_url: sandboxRecreationUrl = null,
    provider_subscription: providerSubscription = null,
    service_connections: serviceConnections = [],
    can_manage_provider_subscription: canManageProviderSubscription = false,
    interactions = [],
    interactions_pagination: interactionsPagination = {},
    cost_report: costReport = {},
    account,
  } = $props();

  useSync({
    [`Agent:${agent.id}`]: ['agent', 'memories', 'interactions', 'interactions_pagination', 'cost_report'],
  });

  let selectedModel = $state(agent.model_id);
  let sendingTestNotification = $state(false);
  let registeringWebhook = $state(false);
  let activeTab = $state(
    activeTabProp === 'identity' ? 'appearance' : activeTabProp === 'model' ? 'settings' : activeTabProp || 'appearance'
  );
  let runtimeManaged = $derived(
    Boolean(agent.birth_committed_at) || agent.runtime === 'external' || agent.runtime === 'offline'
  );
  let showFormActions = $derived(
    activeTab !== 'memory' &&
      activeTab !== 'interactions' &&
      activeTab !== 'costs' &&
      activeTab !== 'integrations' &&
      (!runtimeManaged || activeTab === 'appearance' || activeTab === 'settings' || activeTab === 'hosting')
  );
  let hostingVisited = $state(false);
  $effect(() => {
    if (activeTab === 'hosting') hostingVisited = true;
  });

  const tabs = [
    { id: 'appearance', label: 'Appearance', icon: Palette },
    { id: 'settings', label: 'Settings', icon: Gear },
    { id: 'integrations', label: 'Integrations', icon: Plug },
    { id: 'hosting', label: 'Hosting', icon: CloudArrowUp },
    { id: 'interactions', label: 'Sessions', icon: TerminalWindow },
    { id: 'memory', label: 'Memory', icon: Graph },
    { id: 'costs', label: 'Costs', icon: CurrencyDollar },
  ];

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

  <form
    onsubmit={(e) => {
      e.preventDefault();
      updateAgent();
    }}>
    <div class="flex flex-col md:flex-row gap-6 md:gap-8">
      <AgentSettingsTabs {tabs} bind:activeTab />

      <!-- Content area -->
      <div class="flex-1 min-w-0 space-y-6">
        {#if hostingVisited}
          <div hidden={activeTab !== 'hosting'}>
            <AgentHostingPanel
              {agent}
              {account}
              {runtimeManaged}
              {sandboxRecreationUrl}
              {identityExportUrl}
              {hostingDiagnosticsUrl}
              {providerSubscription}
              {canManageProviderSubscription} />
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
          <AgentSettingsPanel
            {houseAllowance}
            {form}
            groupedModels={grouped_models}
            {runtimeManaged}
            bind:selectedModel />
        {:else if activeTab === 'integrations'}
          <AgentIntegrationsPanel
            {form}
            {agent}
            {account}
            {telegramDeepLink}
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
        {:else if activeTab === 'costs'}
          <AgentCostsPanel report={costReport} />
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
