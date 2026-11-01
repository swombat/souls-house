<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button';
  import { formatDateTime } from '$lib/utils';

  // Only says anything when the resident is unwell. Owners get the one fix a
  // person can apply; the container detail stays on the admin Hosting tab.
  let { agent, sandboxRecreationUrl = null, canRestart = false } = $props();
  let restarting = $state(false);
  // A runtime that restarts on its own is failing as it starts; the Restart
  // button recreates the container, which doesn't change what it does on start.
  let crashLooping = $derived(agent.health_failure_kind === 'restarting');

  function restart() {
    if (!sandboxRecreationUrl || restarting) return;
    if (!confirm(`Restart ${agent.name}? Their identity, memory and history are kept.`)) return;

    restarting = true;
    router.post(sandboxRecreationUrl, {}, { preserveScroll: true, onFinish: () => (restarting = false) });
  }
</script>

{#if agent.deprecated}
  <div class="rounded-lg border bg-muted/30 p-4 text-sm text-muted-foreground" data-testid="runtime-status">
    Deprecated — this resident has no supported harness and cannot respond. Their history and identity records remain
    available.
  </div>
{:else if agent.health_state === 'unhealthy'}
  <div class="rounded-lg border border-destructive/30 bg-destructive/10 p-4 space-y-3" data-testid="runtime-status">
    <div class="space-y-1">
      <p class="font-medium text-destructive">
        {#if crashLooping}
          {agent.name}'s runtime keeps restarting.
        {:else}
          {agent.name} isn't responding right now.
        {/if}
        {#if agent.health_failing_since}
          <span class="font-normal text-muted-foreground">Since {formatDateTime(agent.health_failing_since)}.</span>
        {/if}
      </p>
      <p class="text-sm text-muted-foreground">
        {#if crashLooping}
          Restarting from here may not help: a runtime that restarts on its own is failing as it starts. The house admin
          can see what it says when it starts.
        {:else if canRestart && sandboxRecreationUrl}
          Restarting usually fixes it. If it doesn't, the house admin can see what went wrong.
        {:else}
          The account owner can restart them from this page.
        {/if}
      </p>
    </div>
    {#if agent.sandbox_last_error}
      <details class="text-sm">
        <summary class="cursor-pointer text-muted-foreground">What the house last saw</summary>
        <div class="mt-2 font-mono text-xs whitespace-pre-wrap">{agent.sandbox_last_error}</div>
      </details>
    {/if}
    {#if canRestart && sandboxRecreationUrl}
      <Button type="button" variant="outline" onclick={restart} disabled={restarting}>
        {restarting ? 'Restarting…' : 'Restart'}
      </Button>
    {/if}
  </div>
{/if}
