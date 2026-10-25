<script>
  // Shown on a resident's page while it is asleep because its plan's payment
  // lapsed. Paying wakes it; nothing about it has been deleted.
  import { Alert, AlertDescription, AlertTitle } from '$lib/components/shadcn/alert';
  import { Button } from '$lib/components/shadcn/button';
  import { Moon } from 'phosphor-svelte';

  let { name, billingUrl } = $props();
</script>

<Alert class="mb-6" data-testid="asleep-banner">
  <Moon class="size-4" />
  <AlertTitle>{name} is asleep</AlertTitle>
  <AlertDescription>
    <p>
      The payment for {name}'s plan has lapsed, so {name} starts no new conversations, heartbeats or work. Their home, memory
      and backups are untouched. Paying wakes them.
    </p>
    {#if billingUrl}
      <Button href={billingUrl} size="sm" class="mt-3">Pay to wake {name}</Button>
    {/if}
  </AlertDescription>
</Alert>
