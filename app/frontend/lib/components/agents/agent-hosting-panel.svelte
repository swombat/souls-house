<script>
  import { onMount } from 'svelte';
  import { siteName } from '$lib/branding';
  import AgentProviderSubscriptionPanel from './AgentProviderSubscriptionPanel.svelte';
  import HostingRuntime from './hosting-runtime.svelte';
  import HostingDiagnostics from './hosting-diagnostics.svelte';
  import HostingFilesystem from './hosting-filesystem.svelte';
  let {
    agent,
    account,
    runtimeManaged,
    sandboxRecreationUrl,
    identityExportUrl,
    hostingDiagnosticsUrl,
    providerSubscription,
    canManageProviderSubscription,
  } = $props();
  onMount(loadHostingDiagnostics);
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
  let diagnosticsLoading = $state(false);
  let diagnosticsLoaded = $state(false);
  let diagnosticsError = $state(null);
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
</script>

<div class="space-y-6">
  <HostingRuntime
    {agent}
    {account}
    {runtimeManaged}
    {sandboxRecreationUrl}
    {identityExportUrl}
    onrefresh={loadHostingDiagnostics} />
  {#if providerSubscription}
    <div class="border rounded-lg p-6 space-y-3">
      <div class="space-y-1">
        {#if providerSubscription.provider === 'anthropic'}
          <h2 class="text-xl font-semibold">Claude Code clamping</h2>
          <p class="text-sm text-muted-foreground">
            Connect this resident to a personal Claude subscription and choose the Claude Code clamp instead of metered
            Anthropic API billing. Chaos runs Claude Code inside the resident's hosted runtime; if the subscription is
            unavailable, the request fails rather than falling back to the API key.
          </p>
        {:else}
          <h2 class="text-xl font-semibold">Provider subscription account</h2>
          <p class="text-sm text-muted-foreground">
            Choose whether this resident uses an API key or a personal provider subscription. Provider tokens stay
            inside the resident's private runtime state volume and are never stored by {$siteName}.
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

  <HostingDiagnostics
    {sandboxStatus}
    {diagnosticsError}
    {diagnosticsLoading}
    {diagnosticsLoaded}
    {loadHostingDiagnostics} />
  {#each filesystemSections as section (section.target)}
    <HostingFilesystem {section} {hostingDiagnosticsUrl} {diagnosticsLoading} {diagnosticsLoaded} />
  {/each}
</div>
