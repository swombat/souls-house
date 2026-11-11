<script>
  // A paid resident the house is still making: Stripe is confirming a card
  // payment, a free trial has started, or (an item order) the resident is on
  // the account's bill. An item order never says "Payment received": nothing
  // was charged today.
  import { Alert, AlertDescription, AlertTitle } from '$lib/components/shadcn/alert';

  // The order ({ resident_name, trial, item }), or null.
  let { pending = null } = $props();
</script>

{#if pending}
  <Alert class="mb-6" data-testid="paid-pending">
    <AlertTitle>
      {pending.item ? "On the account's bill" : pending.trial ? 'Free trial started' : 'Payment received'}
    </AlertTitle>
    <AlertDescription>
      {#if pending.item}
        {pending.resident_name || 'Your resident'} is on the account's bill and is being created; it will appear with your
        residents in a moment.
      {:else}
        Stripe is still confirming it. {pending.resident_name || 'Your resident'} will be created as soon as it does, and
        will appear with your residents. You can leave this page.
      {/if}
    </AlertDescription>
  </Alert>
{/if}
