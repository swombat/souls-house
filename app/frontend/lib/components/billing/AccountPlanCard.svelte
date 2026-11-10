<script>
  // The Billing tab's account plan: which one the account is on, where it
  // comes from (a subscription, a grant from the house, or the default), what
  // it includes, and the plans it can move to. Each move says what it costs
  // before the click. Moving between paid plans is a price change on the
  // live subscription; cancelling is in Stripe's portal (Manage billing).
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Badge } from '$lib/components/shadcn/badge/index.js';
  import PlanIncludes from '$lib/components/billing/PlanIncludes.svelte';
  import { accountPlanTaglines, usd } from '$lib/pricing';

  // accountPlan: { id, source: subscription|grant|default, subscription }.
  let { account, accountPlan, accountPlans = [], canPay = false } = $props();

  let busy = $state(null);

  const ORDER = ['companions', 'partners', 'colleagues'];
  const LIVE = ['active', 'trialing', 'past_due', 'incomplete'];

  let current = $derived(accountPlans.find((plan) => plan.id === accountPlan?.id) || null);
  let source = $derived(accountPlan?.source ?? 'default');
  let subscription = $derived(accountPlan?.subscription ?? null);
  let subscriptionLive = $derived(LIVE.includes(subscription?.status));
  // A live subscription changes price in place; without one, a paid plan is a
  // new Stripe Checkout.
  let changing = $derived(subscriptionLive);

  let moves = $derived.by(() => {
    if (!current || !canPay) return [];
    if (subscriptionLive && !['active', 'trialing'].includes(subscription?.status)) return [];
    const rank = ORDER.indexOf(current.id);
    return accountPlans.filter((plan) => {
      if (!plan.purchasable || Number(plan.monthly_usd) <= 0 || plan.id === current.id) return false;
      // A plan the house gave is never lowered by a purchase.
      if (source === 'grant') return ORDER.indexOf(plan.id) > rank;
      return true;
    });
  });

  function date(value) {
    if (!value) return null;
    return new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeZone: 'UTC' }).format(new Date(value));
  }

  function move(plan) {
    busy = plan.id;
    router.post(
      `/accounts/${account.id}/billing/${changing ? 'account_plan_change' : 'account_plan_checkout'}`,
      { plan: plan.id },
      { onFinish: () => (busy = null) }
    );
  }
</script>

{#if current}
  <section class="rounded-lg border p-4" data-testid="account-plan" data-plan={current.id} data-source={source}>
    <div class="flex flex-wrap items-center gap-2">
      <h2 class="font-semibold">Account plan</h2>
      <Badge variant="secondary">{current.name}</Badge>
      {#if source === 'grant'}
        <Badge variant="outline">Given by the house</Badge>
      {/if}
    </div>
    <p class="mt-1 text-sm text-muted-foreground">{accountPlanTaglines[current.id] ?? ''}</p>

    <p class="mt-3 text-sm" data-testid="account-plan-source">
      {#if source === 'grant'}
        The house gave this account {current.name}. There is nothing to pay for it.
      {:else if source === 'subscription' && subscription?.status === 'past_due'}
        The last payment for {current.name} failed. Update the card from Manage billing.
      {:else if source === 'subscription' && subscription?.cancel_at_period_end}
        {current.name} is {usd(current.monthly_usd)} a month + VAT. It ends on {date(subscription.current_period_end)},
        and the account goes back to Companions. Nobody is removed from it.
      {:else if source === 'subscription'}
        {current.name} is {usd(current.monthly_usd)} a month + VAT, on top of the residents.
        {#if subscription?.current_period_end}Renews on {date(subscription.current_period_end)}.{/if}
      {:else}
        Every account starts on Companions. It costs nothing on top of the residents.
      {/if}
    </p>

    <PlanIncludes plan={current} withResident={false} class="mt-3 text-sm" iconClass="text-primary/70" />

    {#if moves.length}
      <div class="mt-4 space-y-3 border-t pt-4" data-testid="account-plan-moves">
        {#each moves as plan (plan.id)}
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <p class="text-sm">
              <span class="font-medium">{plan.name}</span>
              <span class="text-muted-foreground">· {accountPlanTaglines[plan.id] ?? ''}</span>
            </p>
            <Button size="sm" variant="outline" onclick={() => move(plan)} disabled={busy !== null}>
              {busy === plan.id ? 'Opening…' : `Move to ${plan.name} · ${usd(plan.monthly_usd)} a month`}
            </Button>
          </div>
        {/each}
        <p class="text-xs text-muted-foreground" data-testid="account-plan-terms">
          {#if changing}
            The new price starts today. Stripe puts the difference for the rest of this period on the next invoice.
          {:else}
            {moves.map((plan) => `${plan.name} is ${usd(plan.monthly_usd)} a month + VAT`).join('; ')}, on top of the
            residents. It is charged from today, also while a resident's free 14 days are running, and needs a card:
            Stripe asks for one.
          {/if}
        </p>
      </div>
    {/if}
  </section>
{/if}
