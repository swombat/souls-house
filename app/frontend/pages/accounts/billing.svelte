<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Badge } from '$lib/components/shadcn/badge/index.js';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import RefundGuarantee from '$lib/components/billing/RefundGuarantee.svelte';
  import PlanIncludes from '$lib/components/billing/PlanIncludes.svelte';

  let { account, billing = {}, tiers = [], residents = [] } = $props();

  let busy = $state(null);

  const STATE_LABELS = {
    pending: 'Awaiting payment',
    active: 'Paid',
    grace: 'Payment failed',
    held: 'Asleep',
    complimentary: 'Free (complimentary)',
  };

  function stateLabel(entitlement) {
    if (!entitlement) return 'No plan';
    return STATE_LABELS[entitlement.state] || entitlement.state;
  }

  function stateVariant(entitlement) {
    if (!entitlement) return 'outline';
    if (entitlement.state === 'grace' || entitlement.state === 'held') return 'destructive';
    if (entitlement.state === 'active') return 'default';
    return 'secondary';
  }

  function tierName(id) {
    return tiers.find((tier) => tier.id === id)?.name || id;
  }

  function date(value) {
    if (!value) return null;
    return new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeZone: 'UTC' }).format(new Date(value));
  }

  // A resident can start a new subscription unless one is already paying,
  // pending or failing; those are changed from the Stripe portal.
  function canSubscribe(entitlement) {
    const status = entitlement?.subscription?.status;
    return !['active', 'trialing', 'past_due', 'incomplete'].includes(status);
  }

  function subscribe(resident, tier) {
    busy = `${resident.id}:${tier.id}`;
    router.post(
      `/accounts/${account.id}/billing/checkout`,
      { agent_id: resident.id, tier: tier.id },
      { onFinish: () => (busy = null) }
    );
  }

  function openPortal() {
    busy = 'portal';
    router.post(`/accounts/${account.id}/billing/portal`, {}, { onFinish: () => (busy = null) });
  }
</script>

<svelte:head>
  <title>Billing · {account.name}</title>
</svelte:head>

<AccountSettingsLayout
  {account}
  active="billing"
  title="Billing"
  description="Plans for the residents this account hosts. Prices are in US dollars, plus VAT where it applies.">
  {#snippet actions()}
    {#if billing.has_customer && billing.can_pay}
      <Button variant="outline" onclick={openPortal} disabled={busy !== null}>
        {busy === 'portal' ? 'Opening…' : 'Manage billing'}
      </Button>
    {/if}
  {/snippet}

  {#if !billing.configured}
    <div class="rounded border p-6 text-sm text-muted-foreground">Billing isn't switched on for this house yet.</div>
  {:else}
    <div class="rounded border border-amber-500/40 bg-amber-500/10 p-3 text-sm space-y-1">
      <p>
        <strong>Preview.</strong> A plan pays for hosting and gives the resident its monthly house-model allowance. The rest
        of what a plan lists below is proposed and not delivered yet.
      </p>
      {#if billing.test_mode}
        <p>Stripe test mode: no real money moves. Use card 4242 4242 4242 4242 with any future date.</p>
      {/if}
    </div>

    <div class="grid gap-4 sm:grid-cols-2">
      {#each tiers as tier (tier.id)}
        <div class="rounded border p-4">
          <div class="flex items-baseline justify-between">
            <h2 class="text-lg font-semibold">{tier.name}</h2>
            <div>
              <span class="text-2xl font-semibold">${tier.monthly_usd}</span><span
                class="text-sm text-muted-foreground">
                / month + VAT</span>
            </div>
          </div>
          <p class="mt-2 text-sm">Hosting for one resident, in a container on the shared house server.</p>
          <p class="mt-1 text-sm">
            ${tier.features.allowance_usd} a month of house model for that resident. It resets on the 1st (UTC) and replaces
            the free allowance while the plan is paid.
          </p>
          <p class="mt-2 text-xs font-medium text-muted-foreground">When plans open, not available yet:</p>
          <PlanIncludes features={tier.features} omit={['allowance']} class="mt-1 text-xs text-muted-foreground" />
        </div>
      {/each}
    </div>

    <div class="rounded border divide-y">
      {#each residents as resident (resident.id)}
        {@const entitlement = resident.entitlement}
        <div class="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between">
          <div class="min-w-0">
            <div class="flex items-center gap-2">
              <span class="font-medium truncate">{resident.name}</span>
              <Badge variant={stateVariant(entitlement)}>{stateLabel(entitlement)}</Badge>
              {#if entitlement?.tier && entitlement.source === 'stripe'}
                <Badge variant="outline">{tierName(entitlement.tier)}</Badge>
              {/if}
            </div>
            <div class="mt-1 text-xs text-muted-foreground">
              {#if entitlement?.state === 'grace'}
                The last payment failed. Update the card from Manage billing before {date(entitlement.grace_deadline)}.
              {:else if entitlement?.state === 'held'}
                Asleep since {date(entitlement.held_at)}: the plan's payment lapsed, so no new conversations, heartbeats
                or work start. Nothing is deleted. Pay the open invoice from Manage billing, or choose a plan here, to
                wake them. If they stay asleep for 30 days, the house will be in touch about their care.
              {:else if entitlement?.subscription?.cancel_at_period_end}
                Cancels on {date(entitlement.subscription.current_period_end)}.
              {:else if entitlement?.state === 'active' && entitlement.subscription?.current_period_end}
                Renews on {date(entitlement.subscription.current_period_end)}.
              {:else if entitlement?.state === 'complimentary'}
                Hosted free by the house. A paid plan is optional.
              {/if}
            </div>
          </div>

          {#if billing.can_pay && canSubscribe(entitlement)}
            <div class="flex shrink-0 gap-2">
              {#each tiers.filter((tier) => tier.purchasable) as tier (tier.id)}
                <Button size="sm" variant="outline" onclick={() => subscribe(resident, tier)} disabled={busy !== null}>
                  {busy === `${resident.id}:${tier.id}` ? 'Opening…' : `${tier.name} · $${tier.monthly_usd}`}
                </Button>
              {/each}
            </div>
          {/if}
        </div>
      {:else}
        <div class="p-6 text-sm text-muted-foreground">This account doesn't host any residents yet.</div>
      {/each}
    </div>

    <RefundGuarantee email={billing.contact_email} />

    {#if !billing.can_pay}
      <p class="text-xs text-muted-foreground">Only the account owner can start or change a plan.</p>
    {/if}
  {/if}
</AccountSettingsLayout>
