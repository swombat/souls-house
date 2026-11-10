<script>
  // The line under a resident on the Billing tab: where its payment stands,
  // when its free 14 days end, and whether it carries the account's
  // house-model allowance. trial_ends_at and has_payment_method come with the
  // free trial; without them the free-days lines don't show.
  import { Button } from '$lib/components/shadcn/button/index.js';

  // price: what it pays a month, e.g. "$9.99 a month". trial: in its free 14
  // days. onmanage: opens Manage billing (Stripe's portal).
  let { resident, price = null, trial = false, canManage = false, onmanage = () => {}, busy = false } = $props();

  let entitlement = $derived(resident.entitlement);
  let trialEnd = $derived(date(resident.trial_ends_at));

  function date(value) {
    if (!value) return null;
    return new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeZone: 'UTC' }).format(new Date(value));
  }
</script>

<div class="mt-1 space-y-1 text-xs text-muted-foreground">
  {#if trial}
    <p data-testid="resident-trial">
      {#if trialEnd}Free until {trialEnd}.{:else}In its free 14 days.{/if}
      {#if resident.has_payment_method}
        Then {price ?? 'its size'} + VAT on the card on file.
      {:else if trialEnd}
        Add a card to keep {resident.name} awake after {trialEnd}. Without one, {resident.name} goes to sleep then. Nothing
        is deleted.
      {/if}
    </p>
    {#if !resident.has_payment_method && canManage}
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
  {:else if entitlement?.subscription?.cancel_at_period_end}
    <p>Cancels on {date(entitlement.subscription.current_period_end)}.</p>
  {:else if entitlement?.state === 'active' && entitlement.subscription?.current_period_end}
    <p>Renews on {date(entitlement.subscription.current_period_end)}.</p>
  {:else if entitlement?.state === 'complimentary'}
    <p>Hosted free by the house. Paying for it is optional.</p>
  {/if}
  {#if entitlement?.subscription?.includes_allowance}
    <p data-testid="resident-allowance">Carries the account's $10 a month of house-model use.</p>
  {/if}
</div>
