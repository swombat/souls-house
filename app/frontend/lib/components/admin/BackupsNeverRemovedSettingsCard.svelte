<script>
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Switch } from '$lib/components/shadcn/switch';
  import AgentAvatar from '$lib/components/agents/AgentAvatar.svelte';

  let { residents = [], picked = $bindable([]) } = $props();

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
    <CardTitle>Residents whose backups are never removed</CardTitle>
    <CardDescription>
      No resident loses a backup for being old. A resident's backups are kept up to its backup space (60 GB, or 120 GB
      for a Large resident); past that, the oldest are removed one at a time until they fit. A resident switched on here
      is the exception: the house removes none of its backups, however much space they take. The house pays for that
      storage. Turning it off does not remove anything at once; the space rule applies again from the resident's next
      backup.
    </CardDescription>
  </CardHeader>
  <CardContent class="space-y-3">
    <div class="flex items-center justify-between gap-4">
      <input
        type="search"
        placeholder="Find a resident or account"
        aria-label="Find a resident whose backups are never removed"
        class="h-9 w-full max-w-xs rounded-md border bg-background px-3 text-sm"
        bind:value={query} />
      <span class="text-sm text-muted-foreground whitespace-nowrap"
        >{picked.length} of {residents.length} switched on</span>
    </div>
    <div class="max-h-96 overflow-y-auto rounded-md border divide-y">
      {#each groups as [account, members] (account)}
        <div class="px-3 py-2 text-xs font-semibold uppercase tracking-wide text-muted-foreground bg-muted/50">
          {account}
        </div>
        {#each members as resident (resident.id)}
          <label class="flex items-center justify-between gap-3 px-3 py-2 cursor-pointer hover:bg-muted/30">
            <span class="flex items-center gap-2 text-sm">
              <AgentAvatar
                agent={resident}
                class="w-4 h-4 rounded-full flex items-center justify-center"
                iconClass={resident.colour ? `text-${resident.colour}-600 dark:text-${resident.colour}-400` : ''}
                iconSize={16} />
              {resident.name}
              {#if resident.paused}<span class="text-xs text-muted-foreground">(paused)</span>{/if}
            </span>
            <Switch
              aria-label={`Never remove backups of ${resident.name}`}
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
  </CardContent>
</Card>
