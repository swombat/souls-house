<script>
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Switch } from '$lib/components/shadcn/switch';

  let { form, status = {} } = $props();
</script>

<Card>
  <CardHeader>
    <CardTitle>Billing</CardTitle>
    <CardDescription>
      When this is on, every account created from then on pays for each new resident it creates. Accounts that already
      exist are not changed: their residents, and any new ones, stay on the house. Turning it off again changes no
      account either. You can change any single account on the Accounts page.
    </CardDescription>
  </CardHeader>
  <CardContent class="space-y-4">
    <label class="flex items-center gap-3">
      <Switch
        aria-label="New accounts pay for their residents"
        checked={!!form.billing_enabled}
        onCheckedChange={(on) => (form.billing_enabled = on)} />
      <span class="font-medium">New accounts pay for their residents</span>
    </label>

    <p class="text-sm text-muted-foreground" data-testid="billing-status">
      {status.accounts_required ?? 0}
      {status.accounts_required === 1 ? 'account pays' : 'accounts pay'} for new residents now.
      {#if !status.payment_open}
        Paying when a resident is created isn't open yet, so those accounts can't create residents.
      {/if}
      {#if !status.configured}
        Stripe isn't configured on this house.
      {:else if status.test_mode}
        Stripe is in test mode.
      {/if}
    </p>

    {#if status.configured}
      <ul class="space-y-1 text-sm" data-testid="billing-watch">
        <li class:text-rose-600={status.stripe_events_failed > 0}>
          {#if status.stripe_events_failed > 0}
            {status.stripe_events_failed} Stripe {status.stripe_events_failed === 1 ? 'event' : 'events'} the house couldn't
            apply in the last 7 days. Last: <code class="text-xs">{status.stripe_events_last_error}</code>
          {:else}
            Every Stripe event of the last 7 days was applied.
          {/if}
        </li>
        <li class:text-rose-600={status.ungranted_subscriptions > 0}>
          {#if status.ungranted_subscriptions > 0}
            {status.ungranted_subscriptions} paid at-cost {status.ungranted_subscriptions === 1 ? 'subscription' : 'subscriptions'} on an
            account with no code grant in the last 30 days (see the audit log, billing_rate_without_grant).
          {:else}
            No at-cost subscription without a code grant in the last 30 days.
          {/if}
        </li>
        {#if status.portal}
          <!-- Each portal finding on its own line: an unreadable configuration never hides a confirmed unsafe price. -->
          {#if status.portal.error}
            <li class="text-rose-600" data-testid="portal-error">The Stripe portal check failed: {status.portal.error}</li>
          {:else}
            {#if status.portal.at_cost_switchable?.length > 0}
              <li class="text-rose-600" data-testid="portal-unsafe">
                At-cost prices can be chosen in Stripe's portal by anyone with a subscription: {status.portal.at_cost_switchable.join(', ')}.
                Remove them from the portal configuration's plan list.
              </li>
            {/if}
            {#if status.portal.unknown_configurations?.length > 0}
              <li class="text-rose-600" data-testid="portal-unknown">
                The Stripe portal check couldn't read the plan list of {status.portal.unknown_configurations.join(', ')}: treat
                the portal as unverified until it can.
              </li>
            {/if}
            {#if !(status.portal.at_cost_switchable?.length > 0) && !(status.portal.unknown_configurations?.length > 0)}
              <li data-testid="portal-clean">
                {#if status.portal.switchable_prices?.length > 0}
                  Stripe's portal lets customers switch plans among: {status.portal.switchable_prices.join(', ')}. No at-cost
                  price is among them.
                {:else}
                  Stripe's portal lets nobody switch plans; plan changes go through the house.
                {/if}
              </li>
            {/if}
          {/if}
        {/if}
      </ul>
    {/if}
  </CardContent>
</Card>
