<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Badge } from '$lib/components/shadcn/badge/index.js';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import RefundGuarantee from '$lib/components/billing/RefundGuarantee.svelte';
  import PlanIncludes from '$lib/components/billing/PlanIncludes.svelte';

  let { account, billing = {}, tiers = [], offers = [], change_offers = [], codes = null, residents = [] } = $props();

  let busy = $state(null);
  let code = $state('');

  // What the account can buy: offers when the server sends them, else the
  // purchasable standard tiers.
  let buyable = $derived(
    offers.length
      ? offers
      : tiers.filter((tier) => tier.purchasable).map((tier) => ({ ...tier, tier: tier.id, rate: 'standard' }))
  );
  let atCostOffers = $derived(buyable.filter((offer) => offer.rate === 'at_cost'));
  // An existing resident is offered standard plans here; a resident at cost
  // is created from the wizard until moving an existing one is built.
  let subscribable = $derived(buyable.filter((offer) => offer.rate === 'standard'));
  let atCostGrant = $derived(codes?.redemptions?.find((redemption) => redemption.effect === 'at_cost') || null);

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

  function subscribe(resident, offer) {
    busy = `${resident.id}:${offer.id}`;
    router.post(
      `/accounts/${account.id}/billing/checkout`,
      { agent_id: resident.id, tier: offer.tier, rate: offer.rate },
      { onFinish: () => (busy = null) }
    );
  }

  function redeem(event) {
    event.preventDefault();
    if (!code.trim()) return;
    busy = 'code';
    router.post(
      codes.redeem_url,
      { code: code.trim() },
      { onFinish: () => (busy = null), onSuccess: () => (code = '') }
    );
  }

  // A paid resident can move to another plan at its own rate: the offers at
  // that rate, other than the one it is on.
  function canChange(entitlement) {
    return entitlement?.source === 'stripe' && ['active', 'trialing'].includes(entitlement?.subscription?.status);
  }

  function changeOptions(entitlement) {
    const rate = entitlement?.rate ?? 'standard';
    return change_offers.filter((offer) => offer.rate === rate && offer.tier !== entitlement?.tier);
  }

  function changePlan(resident, offer) {
    busy = `${resident.id}:change:${offer.id}`;
    router.post(
      `/accounts/${account.id}/billing/plan_change`,
      { agent_id: resident.id, tier: offer.tier },
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
    {#if billing.test_mode}
      <div class="rounded border border-amber-500/40 bg-amber-500/10 p-3 text-sm" data-testid="billing-test-mode">
        <p>Stripe test mode: no real money moves. Use card 4242 4242 4242 4242 with any future date.</p>
      </div>
    {/if}

    <section class="space-y-3" data-testid="billing-plans">
      <div class="grid gap-3 sm:grid-cols-3">
        {#each tiers as tier (tier.id)}
          {@const atCostOffer = atCostOffers.find((offer) => (offer.tier ?? offer.id) === tier.id)}
          <div class="flex flex-col rounded-lg border p-4">
            <h2 class="font-semibold">{tier.name}</h2>
            <p class="mt-2 flex flex-wrap items-baseline gap-x-1">
              <span class="text-2xl font-semibold">${tier.monthly_usd}</span>
              <span class="whitespace-nowrap text-sm text-muted-foreground">/ month + VAT</span>
            </p>
            {#if atCostGrant && atCostOffer}
              <p class="mt-1 text-sm" data-testid="billing-at-cost-price">
                <span class="font-medium">${atCostOffer.monthly_usd}</span>
                <span class="text-muted-foreground">at cost</span>
              </p>
            {/if}
            <PlanIncludes
              features={tier.features}
              class="mt-3 text-xs text-muted-foreground"
              iconClass="text-primary/70" />
          </div>
        {/each}
      </div>
      <p class="text-xs text-muted-foreground">
        Hosting is a container on the shared house server. A plan's house-model allowance resets on the 1st (UTC) and
        replaces the free allowance while the plan is paid.
      </p>
    </section>

    {#if atCostGrant}
      <div class="rounded-lg border bg-muted/40 p-4 text-sm" data-testid="billing-at-cost">
        <p class="font-medium">
          This account can buy plans at cost <span class="font-normal text-muted-foreground"
            >(code
            <span class="font-mono">{atCostGrant.code}</span>)</span>
        </p>
        <p class="mt-1 text-muted-foreground">
          At cost is the server's price and what comes with it, with no house-model allowance: the resident runs on a
          model subscription or key you connect. Choose it on the Plan step when you create a resident. Moving a
          resident that already has a plan to at cost is coming.
        </p>
      </div>
    {/if}

    <div class="rounded-lg border divide-y">
      {#each residents as resident (resident.id)}
        {@const entitlement = resident.entitlement}
        <div class="flex flex-col gap-3 p-4 lg:flex-row lg:items-start lg:justify-between">
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-2">
              <span class="font-medium truncate">{resident.name}</span>
              <Badge variant={stateVariant(entitlement)}>{stateLabel(entitlement)}</Badge>
              {#if entitlement?.tier && entitlement.source === 'stripe'}
                <Badge variant="outline"
                  >{tierName(entitlement.tier)}{entitlement.rate === 'at_cost' ? ' at cost' : ''}</Badge>
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
            <div class="flex flex-wrap gap-2 lg:justify-end">
              {#each subscribable as offer (offer.id)}
                <Button size="sm" variant="outline" onclick={() => subscribe(resident, offer)} disabled={busy !== null}>
                  {busy === `${resident.id}:${offer.id}` ? 'Opening…' : `${offer.name} · $${offer.monthly_usd}`}
                </Button>
              {/each}
            </div>
          {:else if billing.can_pay && canChange(entitlement)}
            <div class="flex flex-col gap-2 lg:max-w-md lg:items-end" data-testid="plan-change">
              <div class="flex flex-wrap gap-2 lg:justify-end">
                {#each changeOptions(entitlement) as offer (offer.id)}
                  <Button
                    size="sm"
                    variant="outline"
                    onclick={() => changePlan(resident, offer)}
                    disabled={busy !== null}>
                    {busy === `${resident.id}:change:${offer.id}`
                      ? 'Changing…'
                      : `Move to ${offer.name} · $${offer.monthly_usd}`}
                  </Button>
                {/each}
              </div>
              <p class="text-xs text-muted-foreground lg:text-right">
                The price changes now; Stripe puts the difference for the rest of this period on the next invoice. The
                house-model allowance follows the month's rule: this month keeps the higher of the two until the 1st. A
                resident's own server keeps its size for now.
              </p>
            </div>
          {/if}
        </div>
      {:else}
        <div class="p-6 text-sm text-muted-foreground">This account doesn't host any residents yet.</div>
      {/each}
    </div>

    <RefundGuarantee email={billing.contact_email} />

    {#if billing.can_pay && codes?.redeem_url}
      <form class="space-y-2 rounded-lg border p-4" onsubmit={redeem} data-testid="billing-code-form">
        <label for="billing-code" class="block text-sm font-medium">Have a code?</label>
        <div class="flex gap-2">
          <input
            id="billing-code"
            class="h-9 min-w-0 flex-1 rounded-md sm:max-w-xs border bg-background px-3 font-mono text-sm uppercase"
            name="code"
            placeholder="ABCD-1234"
            autocomplete="off"
            bind:value={code}
            disabled={busy !== null} />
          <Button type="submit" variant="outline" disabled={busy !== null || !code.trim()}>
            {busy === 'code' ? 'Checking…' : 'Apply'}
          </Button>
        </div>
        <p class="text-xs text-muted-foreground">
          A code changes which plans this account is offered. It doesn't change a plan already bought.
        </p>
      </form>
    {/if}

    {#if !billing.can_pay}
      <p class="text-xs text-muted-foreground">Only the account owner can start or change a plan.</p>
    {/if}
  {/if}
</AccountSettingsLayout>
