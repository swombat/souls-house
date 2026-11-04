<script>
  import AgentGrid from '$lib/components/agents/AgentGrid.svelte';
  import { createDynamicSync } from '$lib/use-sync';
  import { visibleRefresh } from '$lib/visible-refresh';

  let { residents = [], active_sessions: activeSessions = {}, active_session_totals: totals = null } = $props();

  const updateSync = createDynamicSync();
  $effect(() => {
    updateSync({ 'ResidentSessions:all': ['active_sessions', 'active_session_totals'] });
  });
  // A run that ages out of the working window ends without a broadcast.
  $effect(() => visibleRefresh(['active_sessions', 'active_session_totals']));

  const sum = (kinds) => (kinds ? kinds.chat + kinds.telegram + kinds.other : 0);
  const breakdown = (kinds) => `${kinds.chat} chat · ${kinds.telegram} Telegram · ${kinds.other} other`;
  let query = $state('');
  let hosting = $state('all');

  let live = $derived(residents.filter((agent) => agent.active && !agent.deprecated));
  let cloudCount = $derived(live.filter((agent) => agent.hosting?.kind === 'cloud').length);
  let shown = $derived(
    residents.filter((agent) => {
      if (hosting !== 'all' && agent.hosting?.kind !== hosting) return false;
      const q = query.trim().toLowerCase();
      if (!q) return true;
      return [agent.name, agent.owner_email, agent.account_name, agent.model_label, agent.model_id].some((value) =>
        value?.toLowerCase().includes(q)
      );
    })
  );

  const filters = [
    { value: 'all', label: 'All' },
    { value: 'local', label: 'House server' },
    { value: 'cloud', label: 'Cloud VM' },
  ];
</script>

<svelte:head><title>All residents</title></svelte:head>

<div class="mx-auto max-w-7xl space-y-6 p-6">
  <div>
    <h1 class="text-2xl font-semibold">All residents</h1>
    <p class="text-sm text-muted-foreground">
      {live.length} active · {live.length - cloudCount} on the house server · {cloudCount} on their own cloud VM
    </p>
    {#if totals}
      <p class="mt-1 text-sm" data-testid="site-active-sessions">
        {#if sum(totals.all)}
          <span class="font-medium">{sum(totals.all)} active {sum(totals.all) === 1 ? 'session' : 'sessions'}</span>
          <span class="text-muted-foreground">
            · {breakdown(totals.all)} · house server {sum(totals.house)} · cloud VMs {sum(totals.vm)}</span>
        {:else}
          <span class="text-muted-foreground">No active sessions</span>
        {/if}
      </p>
    {/if}
  </div>

  <div class="flex flex-wrap items-center gap-3">
    <input
      type="search"
      bind:value={query}
      placeholder="Name, owner email, model…"
      aria-label="Filter residents"
      class="h-9 w-64 rounded-md border bg-background px-3 text-sm" />
    <div role="group" aria-label="Hosting" class="inline-flex gap-1 rounded-md border p-1">
      {#each filters as option}
        <button
          type="button"
          aria-pressed={hosting === option.value}
          class="rounded px-2 py-1 text-sm {hosting === option.value ? 'bg-primary text-primary-foreground' : ''}"
          onclick={() => (hosting = option.value)}>{option.label}</button>
      {/each}
    </div>
  </div>

  {#if shown.length}
    <AgentGrid agents={shown} {activeSessions} showActions={false} admin={true} />
  {:else}
    <p class="text-sm text-muted-foreground">No residents match.</p>
  {/if}
</div>
