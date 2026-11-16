<script>
  import AgentGrid from '$lib/components/agents/AgentGrid.svelte';
  import { createDynamicSync } from '$lib/use-sync';
  import { visibleRefresh } from '$lib/visible-refresh';

  let {
    residents = [],
    empty_vms: emptyVms = [],
    active_sessions: activeSessions = {},
    active_session_totals: totals = null,
  } = $props();

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
    { value: 'empty', label: 'Empty VMs' },
  ];

  // Why a server we pay for has nobody on it (Admin::ResidentsController#empty_vms).
  const reasons = {
    spare: 'Spare, not taken yet',
    moved_off: 'Old server, resident moved off',
    rolled_back: 'Kept after its resident went back to the house',
    replaced: "No longer its resident's server",
    resident_gone: 'Its resident is gone',
  };
  let shownVms = $derived(
    emptyVms.filter((vm) => {
      const q = query.trim().toLowerCase();
      if (!q) return true;
      return [vm.label, vm.server_type, vm.location, reasons[vm.reason]].some((value) =>
        value?.toLowerCase().includes(q)
      );
    })
  );
  let emptyTotal = $derived(emptyVms.reduce((sum, vm) => sum + (vm.eur_per_month ?? 0), 0));
  let emptyUnpriced = $derived(emptyVms.some((vm) => vm.eur_per_month == null));
  const euros = (value) => `€${value.toFixed(2)}`;
  const day = (iso) => new Date(iso).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
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
          onclick={() => (hosting = option.value)}
          >{option.label}{#if option.value === 'empty'}&nbsp;({emptyVms.length}){/if}</button>
      {/each}
    </div>
  </div>

  {#if hosting === 'empty'}
    <div data-testid="empty-vms" class="space-y-3">
      <p class="text-sm text-muted-foreground">
        {#if emptyVms.length}
          {emptyVms.length}
          {emptyVms.length === 1 ? 'server' : 'servers'} we pay for with no resident on {emptyVms.length === 1
            ? 'it'
            : 'them'}
          · {euros(emptyTotal)}/month at list price{#if emptyUnpriced}, not counting those without a price{/if}. From
          the house's own purchase records; a server bought outside the house is not here.
        {:else}
          No empty VMs: every server the house holds has a resident on it.
        {/if}
      </p>
      {#if shownVms.length}
        <div class="overflow-x-auto rounded-md border">
          <table class="w-full text-sm">
            <thead class="bg-muted/50 text-left text-muted-foreground">
              <tr>
                <th class="px-3 py-2 font-medium">Why it's empty</th>
                <th class="px-3 py-2 font-medium">Type</th>
                <th class="px-3 py-2 font-medium">Location</th>
                <th class="px-3 py-2 font-medium">State</th>
                <th class="px-3 py-2 font-medium">Since</th>
                <th class="px-3 py-2 font-medium">Hetzner id</th>
                <th class="px-3 py-2 text-right font-medium">Per month</th>
              </tr>
            </thead>
            <tbody>
              {#each shownVms as vm (vm.id)}
                <tr class="border-t">
                  <td class="px-3 py-2">{reasons[vm.reason] ?? vm.reason}</td>
                  <td class="px-3 py-2">
                    {vm.server_type.toUpperCase()}
                    {#if vm.vcpus}<span class="text-muted-foreground">
                        · {vm.vcpus} vCPU · {vm.ram_gb} GB · {vm.disk_gb} GB disk</span
                      >{/if}
                  </td>
                  <td class="px-3 py-2">{vm.location}</td>
                  <td class="px-3 py-2">{vm.state}</td>
                  <td class="px-3 py-2">{day(vm.since)}</td>
                  <td class="px-3 py-2 font-mono text-xs">{vm.provider_server_id}</td>
                  <td class="px-3 py-2 text-right">{vm.eur_per_month == null ? '—' : euros(vm.eur_per_month)}</td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      {:else if emptyVms.length}
        <p class="text-sm text-muted-foreground">No empty VMs match.</p>
      {/if}
    </div>
  {:else if shown.length}
    <AgentGrid agents={shown} {activeSessions} showActions={false} admin={true} />
  {:else}
    <p class="text-sm text-muted-foreground">No residents match.</p>
  {/if}
</div>
