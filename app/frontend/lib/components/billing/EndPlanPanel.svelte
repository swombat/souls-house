<script>
  // The confirmation for ending one resident's paid plan, or the account's
  // own plan (kind 'plan': a plan stands alone on a bill), through
  // Billing::Reconcile: the server's quote, confirmed as-is or not at all.
  // Amounts arrive in cents.
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { usd } from '$lib/pricing';

  let { account, pending } = $props();

  let busy = $state(false);
  let name = $derived(pending.resident_name);
  let immediate = $derived(pending.operation === 'delete');
  let finalTotal = $derived(pending.final_total_cents ?? 0);
  let accountPlan = $derived(pending.kind === 'plan');
  let planName = $derived(pending.plan || 'account');

  function money(cents) {
    return usd((cents ?? 0) / 100);
  }

  function date(value) {
    if (!value) return null;
    return new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeZone: 'UTC' }).format(new Date(value));
  }

  function confirm() {
    busy = true;
    router.post(
      `/accounts/${account.id}/billing/confirm_end_plan`,
      { attempt_id: pending.attempt_id, digest: pending.digest },
      { onFinish: () => (busy = false) }
    );
  }

  function notNow() {
    router.visit(`/accounts/${account.id}/billing`);
  }
</script>

<div
  class="space-y-3 rounded-lg border border-destructive/40 bg-destructive/5 p-4 text-sm"
  data-testid="billing-end-confirm">
  {#if accountPlan}
    <p class="font-medium">End the {planName} plan</p>
    {#if immediate}
      <p>
        The {planName} plan comes off the bill now. Every resident stays{pending.demoted_name
          ? `; ${pending.demoted_name}, the one it included, goes back to its size's full price`
          : ''}.
      </p>
      {#if (pending.next_change_cents ?? 0) > 0}
        <p>
          Your next bill{pending.next_at ? ` on ${date(pending.next_at)}` : ''} goes up by {money(
            pending.next_change_cents
          )}, to {money(pending.next_total_cents)}: the plan's unused part comes off as credit, and {pending.demoted_name ??
            'the resident it included'} costs more than it did.
        </p>
      {:else}
        <p>
          Your next bill{pending.next_at ? ` on ${date(pending.next_at)}` : ''} is {money(pending.next_total_cents)},
          the unused part of this period off as credit. Credit stays on the account's bill. It isn't a refund to your
          card.
        </p>
      {/if}
      <p>After that the account pays {money(pending.recurring_cents)} a month.</p>
    {:else}
      <p>
        The {planName} plan won't renew. The account keeps it until {date(pending.ends_at)}; nobody is removed from the
        account.
      </p>
      {#if finalTotal > 0}
        <p>{money(finalTotal)} from earlier changes is still billed on {date(pending.next_at || pending.ends_at)}.</p>
      {:else}
        <p>Stripe's preview shows nothing more to bill on {date(pending.ends_at)}.</p>
      {/if}
      <p>You can keep the plan any time before then.</p>
    {/if}
  {:else}
    <p class="font-medium">End {name}'s plan</p>
    {#if immediate}
      <p>{name} stops now and sleeps; nothing in their home is deleted.</p>
      {#if pending.next_change_cents < 0}
        <p>
          Your next bill{pending.next_at ? ` on ${date(pending.next_at)}` : ''} goes down by {money(
            -pending.next_change_cents
          )}, to {money(pending.next_total_cents)}: {name}'s plan isn't renewed, and the unused part of this period
          comes off as credit.
        </p>
      {:else}
        <p>
          Your next bill{pending.next_at ? ` on ${date(pending.next_at)}` : ''} is {money(pending.next_total_cents)}.
          {name}'s plan isn't renewed.
        </p>
      {/if}
      <p>Credit stays on the account's bill. It isn't a refund to your card.</p>
      <p>After that the account pays {money(pending.recurring_cents)} a month.</p>
    {:else}
      <p>
        {name}'s plan won't renew. {name} keeps running until {date(pending.ends_at)}, then sleeps; nothing in their
        home is deleted.
      </p>
      {#if finalTotal > 0}
        <p>{money(finalTotal)} from earlier changes is still billed on {date(pending.next_at || pending.ends_at)}.</p>
      {:else}
        <p>Stripe's preview shows nothing more to bill on {date(pending.ends_at)}.</p>
      {/if}
      <p>You can keep the plan any time before then.</p>
    {/if}
  {/if}
  <div class="flex gap-2">
    <Button size="sm" variant="destructive" onclick={confirm} disabled={busy}>
      {#if accountPlan}
        {#if immediate}End the {planName} plan now{:else}Don't renew the {planName} plan{/if}
      {:else if immediate}End {name}'s plan now{:else}Don't renew {name}'s plan{/if}
    </Button>
    <Button size="sm" variant="outline" onclick={notNow} disabled={busy}>Not now</Button>
  </div>
</div>
