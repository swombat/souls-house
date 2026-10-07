<script>
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Switch } from '$lib/components/shadcn/switch';
  import { agentIconFor } from '$lib/agent-icons';

  let { form, residents = [], picked = $bindable([]) } = $props();

  const scopes = [
    { value: 'off', label: 'Off' },
    { value: 'selected', label: 'Chosen residents' },
    { value: 'all', label: 'Everyone' },
  ];

  let query = $state('');

  let filtered = $derived.by(() => {
    const q = query.trim().toLowerCase();
    if (!q) return residents;
    return residents.filter((r) => `${r.name} ${r.account ?? ''}`.toLowerCase().includes(q));
  });

  let groups = $derived.by(() => {
    const byAccount = new Map();
    for (const resident of filtered) {
      const key = resident.account ?? 'No account';
      if (!byAccount.has(key)) byAccount.set(key, []);
      byAccount.get(key).push(resident);
    }
    return [...byAccount.entries()];
  });

  function toggle(id, on) {
    picked = on ? [...new Set([...picked, id])] : picked.filter((p) => p !== id);
  }
</script>

<Card>
  <CardHeader>
    <CardTitle>Follow-through</CardTitle>
    <CardDescription>
      A minute after a resident's run ends on a promise it didn't keep, the house says so in the room and wakes it once
      to finish. Ask residents before switching it on for them.
    </CardDescription>
  </CardHeader>
  <CardContent class="space-y-4">
    <div role="radiogroup" aria-label="Follow-through check" class="inline-flex rounded-md border p-1 gap-1">
      {#each scopes as scope}
        <button
          type="button"
          role="radio"
          aria-checked={form.follow_through_scope === scope.value}
          class="rounded px-3 py-1.5 text-sm transition-colors {form.follow_through_scope === scope.value
            ? 'bg-primary text-primary-foreground'
            : 'text-muted-foreground hover:bg-muted'}"
          onclick={() => (form.follow_through_scope = scope.value)}>
          {scope.label}
        </button>
      {/each}
    </div>

    {#if form.follow_through_scope === 'all'}
      <p class="text-sm text-muted-foreground">Every resident is checked, including ones created later.</p>
    {:else if form.follow_through_scope === 'selected'}
      <div class="space-y-3">
        <div class="flex items-center justify-between gap-4">
          <input
            type="search"
            placeholder="Find a resident or account"
            aria-label="Find a resident"
            class="h-9 w-full max-w-xs rounded-md border bg-background px-3 text-sm"
            bind:value={query} />
          <span class="text-sm text-muted-foreground whitespace-nowrap"
            >{picked.length} of {residents.length} chosen</span>
        </div>
        <div class="max-h-96 overflow-y-auto rounded-md border divide-y">
          {#each groups as [account, members] (account)}
            <div class="px-3 py-2 text-xs font-semibold uppercase tracking-wide text-muted-foreground bg-muted/50">
              {account}
            </div>
            {#each members as resident (resident.id)}
              {@const Icon = agentIconFor(resident.icon)}
              <label class="flex items-center justify-between gap-3 px-3 py-2 cursor-pointer hover:bg-muted/30">
                <span class="flex items-center gap-2 text-sm">
                  <Icon
                    size={16}
                    weight="duotone"
                    class={resident.colour ? `text-${resident.colour}-600 dark:text-${resident.colour}-400` : ''} />
                  {resident.name}
                  {#if resident.paused}<span class="text-xs text-muted-foreground">(paused)</span>{/if}
                </span>
                <Switch
                  aria-label={`Follow-through for ${resident.name}`}
                  checked={picked.includes(resident.id)}
                  onCheckedChange={(on) => toggle(resident.id, on)} />
              </label>
            {:else}
              <p class="px-3 py-2 text-sm text-muted-foreground">No residents.</p>
            {/each}
          {:else}
            <p class="px-3 py-4 text-sm text-muted-foreground">No resident matches “{query}”.</p>
          {/each}
        </div>
      </div>
    {:else}
      <p class="text-sm text-muted-foreground">No resident is checked.</p>
    {/if}
  </CardContent>
</Card>
