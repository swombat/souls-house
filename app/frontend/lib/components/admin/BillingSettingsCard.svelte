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
  </CardContent>
</Card>
