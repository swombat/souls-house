<script>
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';

  let { form, status = {} } = $props();

  const NAMES = { cx23: 'CX23 (Small)', cx33: 'CX33 (Medium)', cx43: 'CX43 (Large)' };
  const types = $derived(status.types ?? []);
  const servers = $derived(status.servers ?? []);
</script>

<Card>
  <CardHeader>
    <CardTitle>Spare servers</CardTitle>
    <CardDescription>
      Hetzner's larger servers are on sale for a few minutes at a time. When a check finds one on sale, the house orders
      what it is short of: one for each resident whose plan names a bigger server than the one it runs on, plus the
      number to keep spare below. A spare costs its monthly price while the house holds it. Nothing is ordered while the
      limit is 0.
    </CardDescription>
  </CardHeader>
  <CardContent class="space-y-4">
    <div class="space-y-2">
      <label for="spare_server_limit" class="font-medium">Most servers held with no resident on them</label>
      <input
        id="spare_server_limit"
        class="block h-10 w-28 rounded-md border bg-background px-3"
        type="number"
        min="0"
        max="20"
        step="1"
        required
        bind:value={form.spare_server_limit} />
      <p class="text-sm text-muted-foreground">
        Counts every spare that might exist, including an order that hasn't been confirmed. {status.counted ?? 0} counted
        now.
      </p>
    </div>

    <div class="grid gap-4 sm:grid-cols-3">
      {#each ['cx23', 'cx33', 'cx43'] as type (type)}
        {@const row = types.find((entry) => entry.server_type === type) ?? {}}
        <div class="space-y-2">
          <label for={`spare_${type}_target`} class="font-medium">{NAMES[type]} to keep spare</label>
          <input
            id={`spare_${type}_target`}
            class="block h-10 w-28 rounded-md border bg-background px-3"
            type="number"
            min="0"
            max="20"
            step="1"
            required
            bind:value={form[`spare_${type}_target`]} />
          <p class="text-sm text-muted-foreground" data-testid={`spare-${type}-status`}>
            {row.waiting ?? 0} waiting, {row.held ?? 0} held or on order.
          </p>
        </div>
      {/each}
    </div>

    {#if status.project_limit_hit_at}
      <p class="text-sm rounded-md border border-amber-500/50 bg-amber-500/10 p-3" data-testid="spare-project-limit">
        Hetzner refused an order because the project has reached its own limit on servers. Nothing more is ordered for
        an hour after that. Ask Hetzner to raise the project's server limit, or release a server.
      </p>
    {/if}

    {#if servers.length}
      <ul class="text-sm space-y-1" data-testid="spare-servers-list">
        {#each servers as server (server.public_id)}
          <li>
            <span class="font-medium">{server.server_type.toUpperCase()}</span> in {server.location}: {server.state}
            <span class="text-muted-foreground">({server.public_id})</span>
          </li>
        {/each}
      </ul>
    {/if}
  </CardContent>
</Card>
