<script>
  import { useForm, router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Palette, Gear, Plug, CloudArrowUp, TerminalWindow, CurrencyDollar } from 'phosphor-svelte';
  import {
    accountAgentsPath,
    accountAgentPath,
    onboardingAccountAgentPath,
    accountAgentTelegramTestPath,
    accountAgentTelegramWebhookPath,
    accountAgentMemoriesPath,
    accountAgentMemoryDiscardPath,
    accountAgentMemoryProtectionPath,
    sendOrientationAccountAgentPath,
    sendTestRequestAccountAgentPath,
  } from '@/routes';
  import { useSync } from '$lib/use-sync';
  import { siteName } from '$lib/branding';
  import AgentAppearancePanel from '$lib/components/agents/AgentAppearancePanel.svelte';
  import AgentEditHeader from '$lib/components/agents/AgentEditHeader.svelte';
  import AgentIntegrationsPanel from '$lib/components/agents/AgentIntegrationsPanel.svelte';
  import AgentMemoryPanel from '$lib/components/agents/AgentMemoryPanel.svelte';
  import AgentSettingsPanel from '$lib/components/agents/AgentSettingsPanel.svelte';
  import AgentSettingsTabs from '$lib/components/agents/AgentSettingsTabs.svelte';
  import AgentInteractionsPanel from '$lib/components/agents/AgentInteractionsPanel.svelte';
  import AgentCostsPanel from '$lib/components/agents/AgentCostsPanel.svelte';
  import AgentProviderSubscriptionPanel from '$lib/components/agents/AgentProviderSubscriptionPanel.svelte';

  let {
    agent,
    telegram_deep_link: telegramDeepLink = null,
    telegram_subscriber_count: telegramSubscriberCount = 0,
    memories = [],
    grouped_models = {},
    colour_options = [],
    icon_options = [],
    active_tab: activeTabProp = null,
    local_dev_endpoint_mode: localDevEndpointMode = false,
    identity_export_url: identityExportUrl = null,
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
  let sendingTestRequest = $state(false);
  let sendingOrientation = $state(false);
  let recreatingSandbox = $state(false);
  let testResult = $state(null);
  let orientationResult = $state(null);
  let sandboxStatus = $state({
    docker_available: null,
    image_present: agent.container_image ? null : false,
    container_exists: agent.container_name && ['external', 'offline', 'provisioning'].includes(agent.runtime),
    identity_volume_exists: agent.uuid ? null : false,
    chaos_volume_exists: agent.uuid ? null : false,
    repo_volume_exists: agent.uuid ? null : false,
    work_volume_exists: agent.uuid ? null : false,
    state_volume_exists: agent.uuid ? null : false,
  });
  let filesystemDump = $state({});
  let containerFilesystemDump = $state({});
  let filePreviews = $state({});
  let expandedFilesystemDirs = $state({});
  let diagnosticsLoading = $state(false);
  let diagnosticsLoaded = $state(false);
  let diagnosticsError = $state(null);
  let showFormActions = $derived(
    activeTab !== 'interactions' &&
      activeTab !== 'costs' &&
      activeTab !== 'integrations' &&
      (!runtimeManaged || activeTab === 'appearance' || activeTab === 'settings' || activeTab === 'hosting')
  );
  let filesystemSections = $derived([
    {
      title: 'Container home filesystem',
      description:
        'Read-only dump of the running container home directory. The persisted Chaos state folder is intentionally hidden.',
      dump: containerFilesystemDump,
      target: 'container_home',
      fallbackRoot: '/home/agent',
    },
    {
      title: 'Identity filesystem',
      description: 'Read-only dump of the mounted identity filesystem.',
      dump: filesystemDump,
      target: 'identity',
      fallbackRoot: '/home/agent/identity',
    },
  ]);

  const tabs = [
    { id: 'appearance', label: 'Appearance', icon: Palette },
    { id: 'settings', label: 'Settings', icon: Gear },
    { id: 'integrations', label: 'Integrations', icon: Plug },
    { id: 'hosting', label: 'Hosting', icon: CloudArrowUp },
    { id: 'interactions', label: 'Sessions', icon: TerminalWindow },
    { id: 'costs', label: 'Costs', icon: CurrencyDollar },
  ];

  let testRequestPath = $derived(sendTestRequestAccountAgentPath(account.id, agent.id));
  let orientationPath = $derived(sendOrientationAccountAgentPath(account.id, agent.id));

  $effect(() => {
    if (activeTab === 'hosting' && !diagnosticsLoaded && !diagnosticsLoading && !diagnosticsError) {
      loadHostingDiagnostics();
    }
  });

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
    },
  });

  function updateAgent() {
    $form.agent.model_id = selectedModel;
    $form.patch(accountAgentPath(account.id, agent.id));
  }

  function deleteMemory(memoryId) {
    if (confirm('Discard this memory?')) {
      router.post(
        accountAgentMemoryDiscardPath(account.id, agent.id, memoryId),
        {},
        {
          preserveScroll: true,
        }
      );
    }
  }

  function undiscardMemory(memoryId) {
    router.delete(accountAgentMemoryDiscardPath(account.id, agent.id, memoryId), { preserveScroll: true });
  }

  function toggleConstitutional(memoryId, isCurrentlyProtected) {
    if (isCurrentlyProtected) {
      router.delete(accountAgentMemoryProtectionPath(account.id, agent.id, memoryId), { preserveScroll: true });
    } else {
      router.post(accountAgentMemoryProtectionPath(account.id, agent.id, memoryId), {}, { preserveScroll: true });
    }
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

  function recreateSandbox() {
    if (!sandboxRecreationUrl || recreatingSandbox) return;

    if (
      !confirm(
        'Refresh this hosted sandbox runtime? This replaces the container with one built from the current runtime image. The identity and Chaos volumes will be preserved, but any container-local files outside mounted volumes will be lost.'
      )
    ) {
      return;
    }

    recreatingSandbox = true;
    router.post(
      sandboxRecreationUrl,
      {},
      {
        preserveScroll: true,
        onFinish() {
          recreatingSandbox = false;
        },
      }
    );
  }

  function createMemory({ content, memoryType }) {
    router.post(
      accountAgentMemoriesPath(account.id, agent.id),
      {
        memory: {
          content,
          memory_type: memoryType,
        },
      },
      {
        preserveScroll: true,
      }
    );
  }

  function csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || '';
  }

  function loadHostingDiagnostics() {
    if (!hostingDiagnosticsUrl || diagnosticsLoading) return;

    diagnosticsLoading = true;
    diagnosticsError = null;

    fetch(hostingDiagnosticsUrl, {
      headers: {
        Accept: 'application/json',
      },
    })
      .then((response) => response.json().then((body) => ({ ok: response.ok, body })))
      .then(({ ok, body }) => {
        if (!ok) {
          throw new Error(body.error || 'Could not load hosting diagnostics');
        }

        sandboxStatus = body.sandbox_status || {};
        filesystemDump = body.filesystem_dump || {};
        containerFilesystemDump = body.container_filesystem_dump || {};
        diagnosticsLoaded = true;
      })
      .catch((error) => {
        diagnosticsError = error.message;
      })
      .finally(() => {
        diagnosticsLoading = false;
      });
  }

  function directoryKey(section, entryOrPath) {
    const path = typeof entryOrPath === 'string' ? entryOrPath : entryOrPath.path;
    return `${section.target}:${path}`;
  }

  function directoryExpanded(section, entry) {
    return expandedFilesystemDirs[directoryKey(section, entry)] === true;
  }

  function toggleDirectory(section, entry) {
    const key = directoryKey(section, entry);
    expandedFilesystemDirs = { ...expandedFilesystemDirs, [key]: !expandedFilesystemDirs[key] };
  }

  function entryVisible(section, entry) {
    if (entry.depth === 0) return true;

    const parts = entry.path.split('/');
    let ancestor = '';
    for (let index = 0; index < parts.length - 1; index += 1) {
      ancestor = ancestor ? `${ancestor}/${parts[index]}` : parts[index];
      if (!expandedFilesystemDirs[directoryKey(section, ancestor)]) return false;
    }

    return true;
  }

  function filePreviewKey(section, entry) {
    return `${section.target}:${entry.path}`;
  }

  function filePreviewUrl(section, entry) {
    const url = new URL(`${hostingDiagnosticsUrl}/file_preview`, window.location.origin);
    url.searchParams.set('target', section.target);
    url.searchParams.set('path', entry.path);
    return url.toString();
  }

  function loadFilePreview(section, entry, event) {
    if (!event.currentTarget.open || !entry.previewable || !hostingDiagnosticsUrl) return;

    const key = filePreviewKey(section, entry);
    if (filePreviews[key]?.loading || filePreviews[key]?.loaded) return;

    filePreviews = { ...filePreviews, [key]: { loading: true } };

    fetch(filePreviewUrl(section, entry), { headers: { Accept: 'application/json' } })
      .then((response) => response.json().then((body) => ({ ok: response.ok, body })))
      .then(({ ok, body }) => {
        filePreviews = {
          ...filePreviews,
          [key]: ok ? { ...body, loaded: true } : { error: body.error || 'Could not load preview', loaded: true },
        };
      })
      .catch((error) => {
        filePreviews = { ...filePreviews, [key]: { error: error.message, loaded: true } };
      });
  }

  function sendTestRequest() {
    sendingTestRequest = true;
    testResult = null;

    fetch(testRequestPath, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': csrfToken(),
      },
    })
      .then((response) => response.json().then((body) => ({ ok: response.ok, body })))
      .then(({ ok, body }) => {
        testResult = ok ? body : { status: 'transport_failed', error: body.error || 'Test request failed' };
        loadHostingDiagnostics();
      })
      .catch((error) => {
        testResult = { status: 'transport_failed', error: error.message };
      })
      .finally(() => {
        sendingTestRequest = false;
      });
  }

  function sendOrientation() {
    sendingOrientation = true;
    orientationResult = null;

    fetch(orientationPath, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': csrfToken(),
      },
    })
      .then((response) => response.json().then((body) => ({ ok: response.ok, body })))
      .then(({ ok, body }) => {
        orientationResult = ok ? body : { status: 'transport_failed', error: body.error || 'Orientation failed' };
        router.reload({ only: ['agent', 'interactions'], preserveScroll: true });
        loadHostingDiagnostics();
      })
      .catch((error) => {
        orientationResult = { status: 'transport_failed', error: error.message };
      })
      .finally(() => {
        sendingOrientation = false;
      });
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
        {#if activeTab === 'appearance'}
          <AgentAppearancePanel
            bind:name={$form.agent.name}
            bind:colour={$form.agent.colour}
            bind:icon={$form.agent.icon}
            nameError={$form.errors.name}
            colourOptions={colour_options}
            iconOptions={icon_options} />
        {:else if activeTab === 'settings'}
          <AgentSettingsPanel {form} groupedModels={grouped_models} {runtimeManaged} bind:selectedModel />
        {:else if activeTab === 'integrations'}
          <AgentIntegrationsPanel
            {form}
            {agent}
            {telegramDeepLink}
            {telegramSubscriberCount}
            {sendingTestNotification}
            {registeringWebhook}
            {serviceConnections}
            onsendTestNotification={sendTestNotification}
            onregisterWebhook={registerWebhook} />
        {:else if activeTab === 'memory'}
          <AgentMemoryPanel
            {agent}
            {memories}
            locked={runtimeManaged}
            oncreate={createMemory}
            ondelete={deleteMemory}
            onundiscard={undiscardMemory}
            ontoggleProtected={toggleConstitutional} />
        {:else if activeTab === 'hosting'}
          <div class="space-y-6">
            <div class="border rounded-lg p-6 space-y-5">
              <div class="space-y-1">
                <h2 class="text-xl font-semibold">Hosting</h2>
                <p class="text-sm text-muted-foreground">
                  Current runtime: <span class="font-medium text-foreground"
                    >{agent.deprecated ? 'Deprecated' : agent.runtime}</span>
                </p>
              </div>

              <div class="grid gap-2 text-sm sm:grid-cols-2">
                {#if agent.container_name}
                  <p>Container: <span class="font-mono">{agent.container_name}</span></p>
                {/if}
                {#if agent.container_image}
                  <p>Image: <span class="font-mono">{agent.container_image}</span></p>
                {/if}
                {#if agent.sandbox_host}
                  <p>Sandbox host: <span class="font-mono">{agent.sandbox_host}</span></p>
                {/if}
                {#if agent.endpoint_url}
                  <p>Dev endpoint: <span class="font-mono">{agent.endpoint_url}</span></p>
                {/if}
                <p>Health: <span class="font-medium">{agent.health_state || 'unknown'}</span></p>
              </div>

              {#if agent.sandbox_last_error}
                <div class="rounded border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
                  <div class="font-medium">Last hosting error</div>
                  <div class="mt-1 font-mono text-xs whitespace-pre-wrap">{agent.sandbox_last_error}</div>
                  {#if agent.sandbox_last_error_at}
                    <div class="mt-1 text-xs opacity-80">At {agent.sandbox_last_error_at}</div>
                  {/if}
                </div>
              {/if}

              {#if agent.deprecated}
                <div class="space-y-3">
                  <p class="text-sm text-muted-foreground">
                    Deprecated — this agent has no supported harness and cannot respond. Its history and identity
                    records remain available.
                  </p>
                </div>
              {:else if agent.runtime === 'provisioning'}
                <div class="space-y-3">
                  <p class="text-sm text-muted-foreground">
                    This born-hosted resident is being prepared. Their initial seed is already committed and cannot be
                    reopened for editing.
                  </p>
                  <a href={onboardingAccountAgentPath(account.id, agent.id)}>
                    <Button type="button" variant="outline">View setup progress</Button>
                  </a>
                </div>
              {:else}
                <div class="space-y-3">
                  <p class="text-sm text-muted-foreground">
                    Identity fields in {$siteName} are now read-only backups. The running resident's identity lives in its
                    hosted filesystem below.
                  </p>
                  <div class="rounded border bg-muted/30 p-3 text-sm">
                    <div class="font-medium">First-wake orientation</div>
                    {#if agent.orientation_completed_at}
                      <p class="mt-1 text-muted-foreground">The most recent orientation wake completed.</p>
                    {:else if agent.orientation_requested_at}
                      <p class="mt-1 text-muted-foreground">
                        An orientation wake has been offered and may still be running.
                      </p>
                    {:else}
                      <p class="mt-1 text-muted-foreground">
                        No orientation wake has been recorded yet. You can offer one without requiring any particular
                        response.
                      </p>
                    {/if}
                  </div>
                  <div class="flex flex-wrap gap-3">
                    <Button
                      type="button"
                      variant="outline"
                      onclick={sendOrientation}
                      disabled={sendingOrientation || agent.health_state !== 'healthy'}>
                      {sendingOrientation
                        ? 'Orienting...'
                        : agent.orientation_requested_at
                          ? 'Re-send orientation'
                          : 'Send orientation'}
                    </Button>
                    <Button type="button" onclick={sendTestRequest} disabled={sendingTestRequest}>
                      {sendingTestRequest ? 'Sending...' : 'Send test trigger'}
                    </Button>
                    {#if sandboxRecreationUrl}
                      <Button
                        type="button"
                        variant="outline"
                        onclick={recreateSandbox}
                        disabled={recreatingSandbox || !runtimeManaged}>
                        {recreatingSandbox ? 'Queueing...' : 'Refresh runtime image'}
                      </Button>
                    {/if}
                    {#if identityExportUrl}
                      <a href={identityExportUrl}>
                        <Button type="button" variant="outline">Download identity export</Button>
                      </a>
                    {/if}
                  </div>
                </div>
              {/if}

              {#if orientationResult}
                <div class="rounded border bg-muted p-3 text-sm">
                  <div>Orientation: <span class="font-mono">{orientationResult.status}</span></div>
                  {#if orientationResult.error}<div class="text-destructive">{orientationResult.error}</div>{/if}
                  {#if orientationResult.runtime_stderr}
                    <details class="mt-2">
                      <summary class="cursor-pointer font-medium text-destructive">Runtime stderr</summary>
                      <pre
                        class="mt-1 overflow-x-auto whitespace-pre-wrap text-xs">{orientationResult.runtime_stderr}</pre>
                    </details>
                  {/if}
                  {#if orientationResult.runtime_stdout}
                    <details class="mt-2">
                      <summary class="cursor-pointer font-medium">Runtime stdout</summary>
                      <pre
                        class="mt-1 overflow-x-auto whitespace-pre-wrap text-xs">{orientationResult.runtime_stdout}</pre>
                    </details>
                  {/if}
                </div>
              {/if}

              {#if testResult}
                <div class="rounded border bg-muted p-3 text-sm">
                  <div>Status: <span class="font-mono">{testResult.status}</span></div>
                  {#if testResult.transport_status}<div>Transport: {testResult.transport_status}</div>{/if}
                  {#if testResult.runtime_status}<div>Runtime: {testResult.runtime_status}</div>{/if}
                  {#if testResult.error}<div class="text-destructive">{testResult.error}</div>{/if}
                  {#if testResult.runtime_stderr}
                    <details class="mt-2">
                      <summary class="cursor-pointer font-medium text-destructive">Runtime stderr</summary>
                      <pre class="mt-1 overflow-x-auto whitespace-pre-wrap text-xs">{testResult.runtime_stderr}</pre>
                    </details>
                  {/if}
                  {#if testResult.runtime_stdout}
                    <details class="mt-2">
                      <summary class="cursor-pointer font-medium">Runtime stdout</summary>
                      <pre class="mt-1 overflow-x-auto whitespace-pre-wrap text-xs">{testResult.runtime_stdout}</pre>
                    </details>
                  {/if}
                </div>
              {/if}
            </div>

            {#if providerSubscription}
              <div class="border rounded-lg p-6 space-y-3">
                <div class="space-y-1">
                  {#if providerSubscription.provider === 'anthropic'}
                    <h2 class="text-xl font-semibold">Claude Code clamping</h2>
                    <p class="text-sm text-muted-foreground">
                      Connect this resident to a personal Claude subscription and choose the Claude Code clamp instead
                      of metered Anthropic API billing. Chaos runs Claude Code inside the resident's hosted runtime; if
                      the subscription is unavailable, the request fails rather than falling back to the API key.
                    </p>
                  {:else}
                    <h2 class="text-xl font-semibold">Provider subscription account</h2>
                    <p class="text-sm text-muted-foreground">
                      Choose whether this resident uses an API key or a personal provider subscription. Provider tokens
                      stay inside the resident's private runtime state volume and are never stored by {$siteName}.
                    </p>
                  {/if}
                </div>
                <AgentProviderSubscriptionPanel
                  {account}
                  subscriptionAgent={providerSubscription}
                  canManage={canManageProviderSubscription}
                  showAgentName={false} />
              </div>
            {/if}

            <div class="border rounded-lg p-6 space-y-3">
              <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                <h2 class="text-xl font-semibold">Docker sandbox diagnostics</h2>
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  onclick={loadHostingDiagnostics}
                  disabled={diagnosticsLoading}>
                  {diagnosticsLoading ? 'Loading...' : 'Refresh diagnostics'}
                </Button>
              </div>
              {#if diagnosticsError}
                <div class="rounded border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
                  {diagnosticsError}
                </div>
              {:else if diagnosticsLoading && !diagnosticsLoaded}
                <p class="text-sm text-muted-foreground">Loading Docker and filesystem diagnostics…</p>
              {/if}
              <div class="grid gap-2 text-sm sm:grid-cols-2">
                <p>
                  Docker daemon:
                  <span class="font-medium"
                    >{sandboxStatus.docker_available === null
                      ? 'checking'
                      : sandboxStatus.docker_available
                        ? 'reachable'
                        : 'not reachable'}</span>
                </p>
                {#if sandboxStatus.docker_version}
                  <p>Docker version: <span class="font-mono">{sandboxStatus.docker_version}</span></p>
                {/if}
                {#if sandboxStatus.configured_helixkit_app_url}
                  <p>
                    Configured callback URL: <span class="font-mono">{sandboxStatus.configured_helixkit_app_url}</span>
                  </p>
                {/if}
                {#if sandboxStatus.container_helixkit_app_url}
                  <p>
                    Container callback URL: <span class="font-mono">{sandboxStatus.container_helixkit_app_url}</span>
                  </p>
                {/if}
                <p>
                  Runtime image present: <span class="font-medium"
                    >{sandboxStatus.image_present === null
                      ? 'checking'
                      : sandboxStatus.image_present
                        ? 'yes'
                        : 'no'}</span>
                </p>
                <p>
                  Container exists: <span class="font-medium"
                    >{sandboxStatus.container_exists === null
                      ? 'checking'
                      : sandboxStatus.container_exists
                        ? 'yes'
                        : 'no'}</span>
                </p>
                {#if sandboxStatus.container_exists}
                  <p>
                    Container image current:
                    <span class="font-medium"
                      >{sandboxStatus.container_image_current === null ||
                      sandboxStatus.container_image_current === undefined
                        ? 'checking'
                        : sandboxStatus.container_image_current
                          ? 'yes'
                          : 'no'}</span>
                  </p>
                  <p>
                    Image stale:
                    <span class={sandboxStatus.image_stale ? 'font-medium text-amber-700' : 'font-medium'}>
                      {sandboxStatus.image_stale === null || sandboxStatus.image_stale === undefined
                        ? 'checking'
                        : sandboxStatus.image_stale
                          ? 'yes'
                          : 'no'}
                    </span>
                  </p>
                {/if}
                {#if sandboxStatus.container_state}
                  <p>Container state: <span class="font-mono">{sandboxStatus.container_state}</span></p>
                {/if}
                {#if sandboxStatus.container_exit_code !== undefined && sandboxStatus.container_exit_code !== null}
                  <p>Exit code: <span class="font-mono">{sandboxStatus.container_exit_code}</span></p>
                {/if}
                <p>
                  Identity volume:
                  <span class="font-medium"
                    >{sandboxStatus.identity_volume_exists === null
                      ? 'checking'
                      : sandboxStatus.identity_volume_exists
                        ? 'present'
                        : 'missing'}</span>
                </p>
                <p>
                  Chaos volume: <span class="font-medium"
                    >{sandboxStatus.chaos_volume_exists === null
                      ? 'checking'
                      : sandboxStatus.chaos_volume_exists
                        ? 'present'
                        : 'missing'}</span>
                </p>
                <p>
                  Repository volume:
                  <span class="font-medium"
                    >{sandboxStatus.repo_volume_exists === null
                      ? 'checking'
                      : sandboxStatus.repo_volume_exists
                        ? 'present'
                        : 'missing'}</span>
                </p>
                <p>
                  Work volume:
                  <span class="font-medium"
                    >{sandboxStatus.work_volume_exists === null
                      ? 'checking'
                      : sandboxStatus.work_volume_exists
                        ? 'present'
                        : 'missing'}</span>
                </p>
                <p>
                  Private state volume:
                  <span class="font-medium"
                    >{sandboxStatus.state_volume_exists === null
                      ? 'checking'
                      : sandboxStatus.state_volume_exists
                        ? 'present'
                        : 'missing'}</span>
                </p>
              </div>
              {#if sandboxStatus.docker_error}
                <div class="rounded border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
                  <div class="font-medium">Docker error</div>
                  <div class="mt-1 font-mono text-xs whitespace-pre-wrap">{sandboxStatus.docker_error}</div>
                </div>
              {/if}
              {#if sandboxStatus.configuration_error}
                <div class="rounded border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
                  <div class="font-medium">Hosting configuration error</div>
                  <div class="mt-1 font-mono text-xs whitespace-pre-wrap">{sandboxStatus.configuration_error}</div>
                </div>
              {/if}
              {#if sandboxStatus.container_exists && sandboxStatus.container_image_current === false}
                <div class="rounded border border-amber-300/40 bg-amber-50 p-3 text-sm text-amber-900">
                  This container was created from an older runtime image. Restarting promotion will recreate the
                  container while preserving its identity, session, repository, and work volumes.
                </div>
              {/if}
              {#if sandboxStatus.container_error}
                <div class="rounded border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
                  <div class="font-medium">Container error</div>
                  <div class="mt-1 font-mono text-xs whitespace-pre-wrap">{sandboxStatus.container_error}</div>
                </div>
              {/if}
              {#if sandboxStatus.log_tail}
                <details class="rounded border bg-muted p-3 text-sm">
                  <summary class="cursor-pointer font-medium">Container log tail</summary>
                  <pre class="mt-2 overflow-x-auto whitespace-pre-wrap text-xs">{sandboxStatus.log_tail}</pre>
                </details>
              {/if}
            </div>

            {#each filesystemSections as section}
              <div class="border rounded-lg p-6 space-y-3">
                <div>
                  <h2 class="text-xl font-semibold">{section.title}</h2>
                  <p class="text-sm text-muted-foreground">
                    {section.description}
                    <span class="font-mono">({section.dump.root || section.fallbackRoot})</span>
                  </p>
                </div>
                {#if section.dump.error}
                  <div class="rounded border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
                    {section.dump.error}
                  </div>
                {:else if diagnosticsLoading && !diagnosticsLoaded}
                  <p class="text-sm text-muted-foreground">Loading filesystem dump…</p>
                {:else if !section.dump.entries || section.dump.entries.length === 0}
                  <p class="text-sm text-muted-foreground">No files found.</p>
                {:else}
                  <div class="space-y-2">
                    {#each section.dump.entries as entry}
                      {#if entryVisible(section, entry)}
                        {#if entry.type === 'directory'}
                          <button
                            type="button"
                            class="block w-full rounded px-2 py-1 text-left font-mono text-xs text-muted-foreground hover:bg-muted"
                            style={`padding-left: ${entry.depth * 1.25 + 0.5}rem`}
                            onclick={() => toggleDirectory(section, entry)}
                            aria-expanded={directoryExpanded(section, entry)}>
                            {directoryExpanded(section, entry) ? '▾' : '▸'} 📁 {entry.name}/
                          </button>
                        {:else}
                          <details
                            class="rounded border bg-muted/40 p-2 text-sm"
                            style={`margin-left: ${entry.depth * 1.25}rem`}
                            ontoggle={(event) => loadFilePreview(section, entry, event)}>
                            <summary class="cursor-pointer font-mono text-xs">
                              📄 {entry.name}
                              {#if entry.size_bytes !== null && entry.size_bytes !== undefined}
                                <span class="text-muted-foreground">({entry.size_bytes} bytes)</span>
                              {/if}
                            </summary>
                            {#if !entry.previewable}
                              <p class="mt-2 text-xs text-muted-foreground">Preview unavailable for this file type.</p>
                            {:else if filePreviews[filePreviewKey(section, entry)]?.loading}
                              <p class="mt-2 text-xs text-muted-foreground">Loading preview…</p>
                            {:else if filePreviews[filePreviewKey(section, entry)]?.error}
                              <p class="mt-2 text-xs text-destructive">
                                {filePreviews[filePreviewKey(section, entry)].error}
                              </p>
                            {:else if filePreviews[filePreviewKey(section, entry)]?.loaded}
                              <pre
                                class="mt-2 max-h-96 overflow-auto whitespace-pre-wrap rounded bg-background p-3 text-xs">{filePreviews[
                                  filePreviewKey(section, entry)
                                ].content}</pre>
                              {#if filePreviews[filePreviewKey(section, entry)].truncated}
                                <p class="mt-1 text-xs text-muted-foreground">Preview truncated.</p>
                              {/if}
                            {:else}
                              <p class="mt-2 text-xs text-muted-foreground">Open to load preview.</p>
                            {/if}
                          </details>
                        {/if}
                      {/if}
                    {/each}
                    {#if section.dump.truncated}
                      <p class="text-xs text-muted-foreground">File listing truncated.</p>
                    {/if}
                  </div>
                {/if}
              </div>
            {/each}
          </div>
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
