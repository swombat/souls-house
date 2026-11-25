<script>
  // The Billing tab's account plan: which one the account is on, where it
  // comes from (a subscription, a grant from the house, or the default), what
  // it includes, and the plans it can move to. Each move says what it costs
  // before the click. Every plan includes one small resident, and a plan can
  // stand alone on a bill (jGgWgj): an account that pays puts a plan on its
  // bill or changes it there, every move quoted before it is confirmed; one
  // with no bill yet chooses the plan its first resident's bill will carry,
  // and nothing is charged until then. Stripe's portal can't cancel
  // (Billing::Portal), so the plan is ended and kept here: it stays when its
  // last resident leaves, and is ended only from here.
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Badge } from '$lib/components/shadcn/badge/index.js';
  import PlanIncludes from '$lib/components/billing/PlanIncludes.svelte';
  import { accountPlanTaglines, usd } from '$lib/pricing';

  // accountPlan: { id, source: subscription|grant|default, subscription,
  // chosen: the plan a first bill will carry, while there is no bill }.
  // trialShown: the tab mentions a free trial (one is offered, or running), so
  // a move says it isn't part of it.
  let { account, accountPlan, accountPlans = [], canPay = false, trialShown = false } = $props();

  let busy = $state(null);

  const ORDER = ['companions', 'partners', 'colleagues'];
  const LIVE = ['active', 'trialing', 'past_due', 'incomplete'];

  let current = $derived(accountPlans.find((plan) => plan.id === accountPlan?.id) || null);
  let source = $derived(accountPlan?.source ?? 'default');
  let subscription = $derived(accountPlan?.subscription ?? null);
  let subscriptionLive = $derived(LIVE.includes(subscription?.status));
  // An account with a bill puts the plan on it, or changes it there, quoted
  // first; without one, the plan is chosen for the first bill and nothing is
  // charged.
  let onBill = $derived(subscriptionLive || Boolean(accountPlan?.bill));
  let changing = $derived(subscriptionLive);
  let chosen = $derived(
    !onBill && accountPlan?.chosen ? accountPlans.find((plan) => plan.id === accountPlan.chosen) || null : null
  );
  // The plan the moves are measured from: the one paid for, or the one chosen.
  let base = $derived(chosen ?? current);
  let trialing = $derived(subscription?.status === 'trialing');

  let moves = $derived.by(() => {
    if (!base || !canPay) return [];
    // The bill can't change while its free days run, nor while a payment is
    // owed, nor while it is set to end.
    if (subscriptionLive && (subscription?.status !== 'active' || subscription?.cancel_at_period_end)) return [];
    const rank = ORDER.indexOf(current.id);
    return accountPlans.filter((plan) => {
      if (!plan.purchasable || plan.id === base.id) return false;
      // A plan the house gave is never lowered by a purchase.
      if (source === 'grant') return ORDER.indexOf(plan.id) > rank;
      return true;
    });
  });

  function date(value) {
    if (!value) return null;
    return new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeZone: 'UTC' }).format(new Date(value));
  }

  // The paid plan is ended here, and an ending made here kept.
  let endable = $derived(
    canPay &&
      source === 'subscription' &&
      ['active', 'past_due'].includes(subscription?.status) &&
      !subscription?.cancel_at_period_end
  );
  let keepable = $derived(
    canPay && source === 'subscription' && subscriptionLive && subscription?.cancel_at_period_end
  );

  // Every move goes through account_plan_checkout: on a bill it comes back
  // as a quote to confirm (?add=), never a change made unseen.
  function move(plan) {
    busy = plan.id;
    router.post(
      `/accounts/${account.id}/billing/account_plan_checkout`,
      { plan: plan.id },
      { onFinish: () => (busy = null) }
    );
  }

  function act(action) {
    busy = action;
    router.post(`/accounts/${account.id}/billing/${action}`, {}, { onFinish: () => (busy = null) });
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
        {current.name} is {usd(current.monthly_usd)} a month + VAT. It ends with the bill on
        {date(subscription.current_period_end)}. Nobody is removed from the account.
      {:else if source === 'subscription' && trialing}
        {current.name} is free until {date(subscription.current_period_end)}, its small resident with it. After that it
        is {usd(current.monthly_usd)} a month + VAT. The plan can be changed once the free days are over.
      {:else if source === 'subscription'}
        {current.name} is {usd(current.monthly_usd)} a month + VAT, one small resident included; any further resident is
        its size. {#if subscription?.current_period_end}Renews on {date(subscription.current_period_end)}.{/if}
      {:else if chosen}
        Your first resident's bill will carry {chosen.name}: {usd(chosen.monthly_usd)} a month + VAT, with that resident
        included. Nothing is charged until then.
      {:else}
        Every account starts on Companions.
      {/if}
    </p>

    <PlanIncludes
      plan={chosen ?? current}
      withResident={accountPlan?.includes_resident !== false}
      class="mt-3 text-sm"
      iconClass="text-primary/70" />

    {#if moves.length}
      <div class="mt-4 space-y-3 border-t pt-4" data-testid="account-plan-moves">
        {#each moves as plan (plan.id)}
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <p class="text-sm">
              <span class="font-medium">{plan.name}</span>
              <span class="text-muted-foreground">· {accountPlanTaglines[plan.id] ?? ''}</span>
            </p>
            <Button size="sm" variant="outline" onclick={() => move(plan)} disabled={busy !== null}>
              {busy === plan.id
                ? 'Saving…'
                : `${changing ? 'Move to' : onBill ? 'Add' : 'Choose'} ${plan.name} · ${usd(plan.monthly_usd)} a month`}
            </Button>
          </div>
        {/each}
        <p class="text-xs text-muted-foreground" data-testid="account-plan-terms">
          {#if changing}
            The new price starts today. Stripe puts the difference for the rest of this period on the next invoice. You
            see what it costs before you confirm.
          {:else if onBill}
            {moves.map((plan) => `${plan.name} is ${usd(plan.monthly_usd)} a month + VAT`).join('; ')}. It goes on the
            account's bill from today, the part of this period on the next invoice. You see what it costs before you
            confirm.
          {:else}
            {moves.map((plan) => `${plan.name} is ${usd(plan.monthly_usd)} a month + VAT`).join('; ')}, one small
            resident included. Choosing one charges nothing now: it starts with your first resident.{trialShown
              ? ' Only Companions has the free days.'
              : ''}
          {/if}
        </p>
      </div>
    {/if}

    {#if endable || keepable}
      <div class="mt-4 flex flex-wrap items-center gap-2 border-t pt-4" data-testid="account-plan-end">
        {#if keepable}
          <Button size="sm" variant="outline" onclick={() => act('keep_plan')} disabled={busy !== null}>
            {busy === 'keep_plan' ? 'Saving…' : `Keep ${current.name}`}
          </Button>
        {:else}
          <Button size="sm" variant="outline" onclick={() => act('end_plan')} disabled={busy !== null}>
            {busy === 'end_plan' ? 'Saving…' : `End ${current.name}`}
          </Button>
          <span class="text-xs text-muted-foreground">You see what it changes before anything is sent.</span>
        {/if}
      </div>
    {/if}
  </section>
{/if}
