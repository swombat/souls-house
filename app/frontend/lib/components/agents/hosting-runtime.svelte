<script>
  import { Button } from '$lib/components/shadcn/button';
  import { siteName } from '$lib/branding';
  import { onboardingAccountAgentPath } from '@/routes';
  import HostingRequestResults from './hosting-request-results.svelte';
  import { createHostingActions } from '$lib/hosting-actions.svelte';
  let { agent, account, runtimeManaged, sandboxRecreationUrl, identityExportUrl, onrefresh } = $props();
  const actions = createHostingActions(() => ({ agent, account, sandboxRecreationUrl, onrefresh }));
</script>

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
        Deprecated — this resident has no supported harness and cannot respond. Its history and identity records remain
        available.
      </p>
    </div>
  {:else if agent.runtime === 'provisioning'}
    <div class="space-y-3">
      <p class="text-sm text-muted-foreground">
        This born-hosted resident is being prepared. Their initial seed is already committed and cannot be reopened for
        editing.
      </p>
      <a href={onboardingAccountAgentPath(account.id, agent.id)}>
        <Button type="button" variant="outline">View setup progress</Button>
      </a>
    </div>
  {:else}
    <div class="space-y-3">
      <p class="text-sm text-muted-foreground">
        Identity fields in {$siteName} are now read-only backups. The running resident's identity lives in its hosted filesystem
        below.
      </p>
      <div class="rounded border bg-muted/30 p-3 text-sm">
        <div class="font-medium">First-wake orientation</div>
        {#if agent.orientation_completed_at}
          <p class="mt-1 text-muted-foreground">The most recent orientation wake completed.</p>
        {:else if agent.orientation_requested_at}
          <p class="mt-1 text-muted-foreground">An orientation wake has been offered and may still be running.</p>
        {:else}
          <p class="mt-1 text-muted-foreground">
            No orientation wake has been recorded yet. You can offer one without requiring any particular response.
          </p>
        {/if}
      </div>
      <div class="flex flex-wrap gap-3">
        <Button
          type="button"
          variant="outline"
          onclick={actions.sendOrientation}
          disabled={actions.sendingOrientation || agent.health_state !== 'healthy'}>
          {actions.sendingOrientation
            ? 'Orienting...'
            : agent.orientation_requested_at
              ? 'Re-send orientation'
              : 'Send orientation'}
        </Button>
        <Button type="button" onclick={actions.sendTestRequest} disabled={actions.sendingTestRequest}>
          {actions.sendingTestRequest ? 'Sending...' : 'Send test trigger'}
        </Button>
        {#if sandboxRecreationUrl}
          <Button
            type="button"
            variant="outline"
            onclick={actions.recreateSandbox}
            disabled={actions.recreatingSandbox || !runtimeManaged}>
            {actions.recreatingSandbox ? 'Queueing...' : 'Refresh runtime image'}
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

  <HostingRequestResults orientationResult={actions.orientationResult} testResult={actions.testResult} />
</div>
