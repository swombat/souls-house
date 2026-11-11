<script>
  // The line under a resident on the Billing tab: where its payment stands
  // and when its free 14 days end. trial_ends_at is set while the resident is
  // in its free trial. The house doesn't know whether a card is on the account, so
  // the trial's wording is true either way.
  import { Button } from '$lib/components/shadcn/button/index.js';

  // price: what it pays a month, e.g. "$9.99 a month". trial: in its free 14
  // days. onmanage: opens Manage billing (Stripe's portal).
  let { resident, price = null, trial = false, canManage = false, onmanage = () => {}, busy = false } = $props();

  let entitlement = $derived(resident.entitlement);
  // A plan set to end wins over the trial wording: adding a card does not undo
  // the cancellation, only Keep does.
  let ending = $derived(!!entitlement?.subscription?.cancel_at_period_end);
  let trialEnd = $derived(date(resident.trial_ends_at));
  // What the resident costs once its trial ends, e.g. " at $9.99 a month + VAT".
  let afterTrial = $derived(price ? ` at ${price} + VAT` : '');

  function date(value) {
    if (!value) return null;
    return new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeZone: 'UTC' }).format(new Date(value));
  }
</script>

<div class="mt-1 space-y-1 text-xs text-muted-foreground">
  {#if trial && !ending}
    <p data-testid="resident-trial">
      <span class="font-medium text-foreground">
        {#if trialEnd}Free trial until {trialEnd}.{:else}On its free trial.{/if}
      </span>
      Add a card from Manage billing to keep {resident.name} awake after {trialEnd ?? 'the trial'}{afterTrial}; with no
      card, {resident.name} goes to sleep {trialEnd ? `on ${trialEnd}` : 'then'} and nothing is deleted.
    </p>
    {#if canManage}
      <Button size="sm" variant="link" class="h-auto p-0 text-xs" onclick={onmanage} disabled={busy}
        >Manage billing</Button>
    {/if}
  {:else if entitlement?.state === 'grace'}
    <p>The last payment failed. Update the card from Manage billing before {date(entitlement.grace_deadline)}.</p>
  {:else if entitlement?.state === 'held'}
    <p>
      Asleep since {date(entitlement.held_at)}: the resident's payment lapsed, so no new conversations, heartbeats or
      work start. Nothing is deleted. Pay the open invoice from Manage billing, or choose a size here, to wake them. If
      they stay asleep for 30 days, the house will be in touch about their care.
    </p>
  {:else if ending}
    <p>Ends on {date(entitlement.subscription.current_period_end)}; won't renew.</p>
  {:else if entitlement?.state === 'active' && entitlement.subscription?.current_period_end}
    <p>Renews on {date(entitlement.subscription.current_period_end)}.</p>
  {:else if entitlement?.state === 'complimentary'}
    <p>Hosted free by the house. Paying for it is optional.</p>
  {/if}
</div>
