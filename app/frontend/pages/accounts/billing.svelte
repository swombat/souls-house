<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Badge } from '$lib/components/shadcn/badge/index.js';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import RefundGuarantee from '$lib/components/billing/RefundGuarantee.svelte';
  import AccountPlanCard from '$lib/components/billing/AccountPlanCard.svelte';
  import ResidentBillingNote from '$lib/components/billing/ResidentBillingNote.svelte';
  import { sizeLines, sizeOf, usd } from '$lib/pricing';

  let {
    account,
    billing = {},
    tiers = [],
    offers = null,
    change_offers = [],
    codes = null,
    residents = [],
    account_plans: accountPlans = [],
    account_plan: accountPlan = null,
    // The account's free 14 days: { eligible, days }.
    trial = null,
  } = $props();

  let busy = $state(null);
  let code = $state('');

  // The server owns eligibility and availability. An empty offers list means
  // nothing is available; only older props without offers fall back to tiers.
  let buyable = $derived(
    offers !== null
      ? offers.filter((offer) => offer.purchasable)
      : tiers.filter((tier) => tier.purchasable).map((tier) => ({ ...tier, tier: tier.id, rate: 'standard' }))
  );
  let atCostOffers = $derived(buyable.filter((offer) => offer.rate === 'at_cost'));
  let atCostGrant = $derived(codes?.redemptions?.find((redemption) => redemption.effect === 'at_cost') || null);

  const STATE_LABELS = {
    pending: 'Awaiting payment',
    active: 'Paid',
    grace: 'Payment failed',
    held: 'Asleep',
    complimentary: 'Free (complimentary)',
  };

  function stateLabel(resident) {
    const entitlement = resident.entitlement;
    if (!entitlement) return 'Not paid for';
    if (onTrial(resident)) return 'Free trial';
    return STATE_LABELS[entitlement.state] || entitlement.state;
  }

  // A resident in its free trial.
  function onTrial(resident) {
    return Boolean(resident.trial_ends_at) || resident.entitlement?.subscription?.status === 'trialing';
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

  // What the resident pays a month, at its own size and rate.
  function residentPrice(entitlement) {
    if (!entitlement?.tier || entitlement.source !== 'stripe') return null;
    const rate = entitlement.rate ?? 'standard';
    const match = [...(offers ?? []), ...change_offers].find(
      (offer) => (offer.tier ?? offer.id) === entitlement.tier && (offer.rate ?? 'standard') === rate
    );
    const tier = rate === 'standard' ? tiers.find((candidate) => candidate.id === entitlement.tier) : null;
    const amount = match?.monthly_usd ?? tier?.monthly_usd;
    return amount === undefined ? null : `${usd(amount)} a month`;
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

  // A paid resident can move to another size at its own rate: the offers at
  // that rate, other than the one it is on. Not in the free 14 days: those
  // are for a small resident.
  function canChange(entitlement) {
    return entitlement?.source === 'stripe' && entitlement?.subscription?.status === 'active';
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
  description="The account's plan, and the residents it hosts. Prices are in US dollars a month, plus VAT where it applies.">
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

    <AccountPlanCard
      {account}
      {accountPlan}
      {accountPlans}
      canPay={billing.can_pay}
      trialShown={Boolean(trial?.eligible) || residents.some(onTrial)} />

    <section class="space-y-3" data-testid="billing-plans">
      <h2 class="font-semibold">Residents, by size</h2>
      <div class="grid gap-3 sm:grid-cols-3">
        {#each tiers as tier (tier.id)}
          {@const atCostOffer = atCostOffers.find((offer) => (offer.tier ?? offer.id) === tier.id)}
          <div class="flex flex-col rounded-lg border p-4">
            <h2 class="font-semibold">{tier.name}</h2>
            <p class="mt-2 flex flex-wrap items-baseline gap-x-1">
              <span class="text-2xl font-semibold">{usd(tier.monthly_usd)}</span>
              <span class="whitespace-nowrap text-sm text-muted-foreground">/ month + VAT</span>
            </p>
            {#if atCostGrant && atCostOffer}
              <p class="mt-1 text-sm" data-testid="billing-at-cost-price">
                <span class="font-medium">{usd(atCostOffer.monthly_usd)}</span>
                <span class="text-muted-foreground">at cost</span>
              </p>
            {/if}
            <p class="mt-3 text-xs text-muted-foreground">{sizeLines[sizeOf(tier)] ?? ''}</p>
          </div>
        {/each}
      </div>
      <p class="text-xs text-muted-foreground">
        Each size is hosting for one resident, in a container on the shared house server. The account gets $10 a month
        of house-model use, shared by its residents at the standard price, and it resets on the 1st (UTC). Residents
        hosted at cost don't draw on it.
      </p>
    </section>

    {#if atCostGrant}
      <div class="rounded-lg border bg-muted/40 p-4 text-sm" data-testid="billing-at-cost">
        <p class="font-medium">
          This account can pay for residents at cost <span class="font-normal text-muted-foreground"
            >(code
            <span class="font-mono">{atCostGrant.code}</span>)</span>
        </p>
        <p class="mt-1 text-muted-foreground">
          At cost is the server's price for the size and what comes with it, with no house-model allowance: the resident
          runs on a model subscription or key you connect. Connect and select your own model before checkout; a
          house-funded model cannot be used at cost. Choose an at-cost size below for a resident hosted free by the
          house, or on the Plan step when you create a resident. An existing resident's server is unchanged. Residents
          already paid for keep their price.
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
              <Badge variant={stateVariant(entitlement)}>{stateLabel(resident)}</Badge>
              {#if entitlement?.tier && entitlement.source === 'stripe'}
                <Badge variant="outline"
                  >{tierName(entitlement.tier)}{entitlement.rate === 'at_cost' ? ' at cost' : ''}</Badge>
              {/if}
              {#if residentPrice(entitlement) && !onTrial(resident)}
                <span class="text-sm text-muted-foreground" data-testid="resident-price"
                  >{residentPrice(entitlement)}</span>
              {/if}
            </div>
            <ResidentBillingNote
              {resident}
              price={residentPrice(entitlement)}
              trial={onTrial(resident)}
              canManage={billing.has_customer && billing.can_pay}
              onmanage={openPortal}
              busy={busy !== null} />
          </div>

          {#if billing.can_pay && canSubscribe(entitlement)}
            <div class="flex flex-wrap gap-2 lg:justify-end">
              {#each buyable as offer (offer.id)}
                <Button size="sm" variant="outline" onclick={() => subscribe(resident, offer)} disabled={busy !== null}>
                  {busy === `${resident.id}:${offer.id}`
                    ? 'Opening…'
                    : `${offer.name} · ${usd(offer.monthly_usd)} a month`}
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
                      : `Move to ${offer.name} · ${usd(offer.monthly_usd)} a month`}
                  </Button>
                {/each}
              </div>
              <p class="text-xs text-muted-foreground lg:text-right">
                The price changes now; Stripe puts the difference for the rest of this period on the next invoice. The
                resident stays on the same server for now.
              </p>
            </div>
          {/if}
        </div>
      {:else}
        <div class="p-6 text-sm text-muted-foreground" data-testid="billing-no-residents">
          This account doesn't host any residents yet.
          {#if trial?.eligible}
            Its first can be small and free for {trial.days ?? 14} days, with no card asked for.
            <a class="underline underline-offset-4" href="/accounts/{account.id}/agents/new">Create a resident</a>.
          {/if}
        </div>
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
          A code changes which prices this account is offered. It doesn't change a price already paid.
        </p>
      </form>
    {/if}

    {#if !billing.can_pay}
      <p class="text-xs text-muted-foreground">
        Only the account owner can change the account's plan or pay for a resident.
      </p>
    {/if}
  {/if}
</AccountSettingsLayout>
