<script>
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Switch } from '$lib/components/shadcn/switch';

  let { form, accounts = [], picked = $bindable([]) } = $props();

  function toggle(id, on) {
    picked = on ? [...new Set([...picked, id])] : picked.filter((p) => p !== id);
  }

  const intervals = [
    { value: 0, label: 'Off' },
    { value: 10, label: '10 min' },
    { value: 30, label: '30 min' },
    { value: 60, label: '60 min' },
  ];
</script>

<Card>
  <CardHeader>
    <CardTitle>Stalled threads</CardTitle>
    <CardDescription>
      Judges rooms that have gone quiet: whose move is it, and is it a resident's? Shadow mode only records the verdict
      (<a class="underline" href="/admin/stalled_sweeps">see the log</a>); it posts nothing and wakes nobody. Only rooms in
      the accounts chosen below are read.
    </CardDescription>
  </CardHeader>
  <CardContent class="space-y-4">
    <div role="radiogroup" aria-label="Stalled-thread sweep interval" class="inline-flex gap-1 rounded-md border p-1">
      {#each intervals as interval}
        <button
          type="button"
          role="radio"
          aria-checked={Number(form.stalled_sweep_minutes ?? 0) === interval.value}
          class="rounded px-3 py-1.5 text-sm transition-colors {Number(form.stalled_sweep_minutes ?? 0) === interval.value
            ? 'bg-primary text-primary-foreground'
            : 'text-muted-foreground hover:bg-muted'}"
          onclick={() => (form.stalled_sweep_minutes = interval.value)}>
          {interval.label}
        </button>
      {/each}
    </div>
    <div class="max-h-72 divide-y overflow-y-auto rounded-md border">
      {#each accounts as account (account.id)}
        <label class="flex cursor-pointer items-center justify-between gap-3 px-3 py-2 text-sm hover:bg-muted/30">
          <span>
            {account.name}
            {#if account.disabled}<span class="text-xs text-muted-foreground">(disabled)</span>{/if}
          </span>
          <Switch
            aria-label={`Stalled-thread sweep for ${account.name}`}
            checked={picked.includes(account.id)}
            onCheckedChange={(on) => toggle(account.id, on)} />
        </label>
      {:else}
        <p class="px-3 py-2 text-sm text-muted-foreground">No accounts.</p>
      {/each}
    </div>
    <p class="text-sm text-muted-foreground">{picked.length} of {accounts.length} accounts chosen.</p>
  </CardContent>
</Card>
