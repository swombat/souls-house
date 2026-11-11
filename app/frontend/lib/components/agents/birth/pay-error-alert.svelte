<script>
  // Why the last try to create a paid resident stopped. A card that was
  // declined, a free trial that didn't start, and money taken but a resident
  // not yet made each read differently. An item order (added to the account's
  // bill, nothing charged today) never reads as a declined card: before the
  // owner accepted it, it is "Not added yet"; once accepted, "Still being
  // created".
  import { Alert, AlertDescription, AlertTitle } from '$lib/components/shadcn/alert';

  let {
    payError = null,
    // The account's free 14 days apply to this choice.
    free = false,
    // Paid, or (an item order) accepted: the house hasn't finished.
    payPaid = false,
    // The order is an item order.
    deferred = false,
  } = $props();
</script>

{#if payError}
  <Alert variant="destructive" data-testid="plan-pay-error">
    {#if free && !payPaid}
      <AlertTitle>The free trial didn't start</AlertTitle>
      <AlertDescription>{payError} Nothing was created.</AlertDescription>
    {:else if deferred && payPaid}
      <AlertTitle>Still being created</AlertTitle>
      <AlertDescription>{payError}</AlertDescription>
    {:else if deferred}
      <AlertTitle>Not added yet</AlertTitle>
      <AlertDescription>{payError}</AlertDescription>
    {:else if payPaid}
      <AlertTitle>Almost there</AlertTitle>
      <AlertDescription>{payError}</AlertDescription>
    {:else}
      <AlertTitle>The payment didn't go through</AlertTitle>
      <AlertDescription>
        {payError} Nothing was created. You can try again, or use a different card.
      </AlertDescription>
    {/if}
  </Alert>
{/if}
