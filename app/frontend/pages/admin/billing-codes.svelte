<script>
  // Site Admin → Billing codes. A code is the invitation; an account's
  // redemption is the grant. Revoking a code stops new redemptions only;
  // withdrawing a redemption stops that account's future purchases at the
  // rate and never touches a subscription already bought.
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Badge } from '$lib/components/shadcn/badge/index.js';

  let { effects = ['at_cost'], codes = [], redemptions = [], errors = {} } = $props();

  let form = $state({ code: '', effect: 'at_cost', max_redemptions: '', expires_at: '', note: '' });
  let busy = $state(null);

  const EFFECT_LABELS = { at_cost: 'At cost: the machine’s price, no house-model allowance' };

  function date(value) {
    if (!value) return '–';
    return new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeZone: 'UTC' }).format(new Date(value));
  }

  function create(event) {
    event.preventDefault();
    busy = 'create';
    router.post(
      '/admin/billing_codes',
      { billing_code: { ...form, max_redemptions: form.max_redemptions || null, expires_at: form.expires_at || null } },
      {
        onFinish: () => (busy = null),
        onSuccess: () => (form = { code: '', effect: 'at_cost', max_redemptions: '', expires_at: '', note: '' }),
      }
    );
  }

  function revoke(code) {
    if (!confirm(`Withdraw ${code.code}? Accounts that already redeemed it keep their grant.`)) return;
    busy = `revoke:${code.id}`;
    router.patch(`/admin/billing_codes/${code.id}/revoke`, {}, { onFinish: () => (busy = null) });
  }

  function withdraw(redemption) {
    if (!confirm(`Withdraw ${redemption.account}’s grant from ${redemption.code}? Plans already bought are unchanged.`)) return;
    busy = `withdraw:${redemption.id}`;
    router.patch(`/admin/billing_code_redemptions/${redemption.id}/withdraw`, {}, { onFinish: () => (busy = null) });
  }

  function status(code) {
    if (code.revoked_at) return { label: 'Withdrawn', variant: 'secondary' };
    if (code.expires_at && new Date(code.expires_at) <= new Date()) return { label: 'Expired', variant: 'secondary' };
    if (code.max_redemptions && code.redemptions_count >= code.max_redemptions) return { label: 'Used up', variant: 'secondary' };
    return { label: 'Open', variant: 'default' };
  }
</script>

<svelte:head><title>Billing codes</title></svelte:head>

<div class="mx-auto max-w-6xl space-y-8 p-6">
  <div>
    <h1 class="text-2xl font-semibold">Billing codes</h1>
    <p class="mt-1 text-sm text-muted-foreground">
      A code is redeemed once per account from its Billing tab. Redeeming changes what that account is offered from
      then on; it never changes a plan already bought. Withdrawing a code stops new redemptions only.
    </p>
  </div>

  <form class="grid gap-3 rounded border p-4 sm:grid-cols-2" onsubmit={create} data-testid="billing-code-new">
    <label class="flex flex-col gap-1 text-sm">
      <span class="font-medium">Code</span>
      <input class="rounded border bg-background px-3 py-1.5 font-mono uppercase" bind:value={form.code}
        placeholder="Leave empty to make one up" autocomplete="off" />
      {#if errors.code}<span class="text-xs text-destructive">{errors.code.join(', ')}</span>{/if}
    </label>
    <label class="flex flex-col gap-1 text-sm">
      <span class="font-medium">Effect</span>
      <select class="rounded border bg-background px-3 py-1.5" bind:value={form.effect}>
        {#each effects as effect (effect)}
          <option value={effect}>{EFFECT_LABELS[effect] ?? effect}</option>
        {/each}
      </select>
    </label>
    <label class="flex flex-col gap-1 text-sm">
      <span class="font-medium">Redemptions allowed</span>
      <input class="rounded border bg-background px-3 py-1.5" type="number" min="1" bind:value={form.max_redemptions}
        placeholder="No limit" />
      {#if errors.max_redemptions}<span class="text-xs text-destructive">{errors.max_redemptions.join(', ')}</span>{/if}
    </label>
    <label class="flex flex-col gap-1 text-sm">
      <span class="font-medium">Expires</span>
      <input class="rounded border bg-background px-3 py-1.5" type="datetime-local" bind:value={form.expires_at} />
    </label>
    <label class="flex flex-col gap-1 text-sm sm:col-span-2">
      <span class="font-medium">Note (who it's for)</span>
      <input class="rounded border bg-background px-3 py-1.5" bind:value={form.note} placeholder="Pepe, Janis's server" />
    </label>
    <div class="sm:col-span-2">
      <Button type="submit" disabled={busy !== null}>{busy === 'create' ? 'Making…' : 'Make a code'}</Button>
    </div>
  </form>

  <section class="space-y-2">
    <h2 class="text-lg font-semibold">Codes</h2>
    {#if codes.length === 0}
      <p class="text-sm text-muted-foreground">No codes yet.</p>
    {:else}
      <div class="overflow-x-auto rounded border">
        <table class="w-full text-sm">
          <thead class="bg-muted/40 text-left text-xs uppercase text-muted-foreground">
            <tr>
              <th class="p-2">Code</th><th class="p-2">Effect</th><th class="p-2">Used</th><th class="p-2">Expires</th>
              <th class="p-2">Note</th><th class="p-2">Made by</th><th class="p-2">Status</th><th class="p-2"></th>
            </tr>
          </thead>
          <tbody class="divide-y">
            {#each codes as code (code.id)}
              {@const s = status(code)}
              <tr>
                <td class="p-2 font-mono">{code.code}</td>
                <td class="p-2">{code.effect.replace('_', ' ')}</td>
                <td class="p-2">{code.redemptions_count}{code.max_redemptions ? ` / ${code.max_redemptions}` : ''}</td>
                <td class="p-2">{date(code.expires_at)}</td>
                <td class="p-2 text-muted-foreground">{code.note ?? ''}</td>
                <td class="p-2">{code.created_by}</td>
                <td class="p-2"><Badge variant={s.variant}>{s.label}</Badge></td>
                <td class="p-2 text-right">
                  {#if !code.revoked_at}
                    <Button size="sm" variant="ghost" onclick={() => revoke(code)} disabled={busy !== null}>Withdraw</Button>
                  {/if}
                </td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}
  </section>

  <section class="space-y-2">
    <h2 class="text-lg font-semibold">Redemptions</h2>
    {#if redemptions.length === 0}
      <p class="text-sm text-muted-foreground">Nobody has redeemed a code yet.</p>
    {:else}
      <div class="overflow-x-auto rounded border">
        <table class="w-full text-sm">
          <thead class="bg-muted/40 text-left text-xs uppercase text-muted-foreground">
            <tr>
              <th class="p-2">Account</th><th class="p-2">Code</th><th class="p-2">Effect</th><th class="p-2">By</th>
              <th class="p-2">When</th><th class="p-2">Status</th><th class="p-2"></th>
            </tr>
          </thead>
          <tbody class="divide-y">
            {#each redemptions as redemption (redemption.id)}
              <tr>
                <td class="p-2">{redemption.account}</td>
                <td class="p-2 font-mono">{redemption.code}</td>
                <td class="p-2">{redemption.effect.replace('_', ' ')}</td>
                <td class="p-2">{redemption.redeemed_by}</td>
                <td class="p-2">{date(redemption.redeemed_at)}</td>
                <td class="p-2">
                  {#if redemption.withdrawn_at}<Badge variant="secondary">Withdrawn {date(redemption.withdrawn_at)}</Badge>
                  {:else}<Badge>Live</Badge>{/if}
                </td>
                <td class="p-2 text-right">
                  {#if !redemption.withdrawn_at}
                    <Button size="sm" variant="ghost" onclick={() => withdraw(redemption)} disabled={busy !== null}>Withdraw</Button>
                  {/if}
                </td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}
  </section>
</div>
