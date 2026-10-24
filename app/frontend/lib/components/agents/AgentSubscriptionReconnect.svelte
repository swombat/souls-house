<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button';
  import ProviderConnectionDialog from './provider-connection-dialog.svelte';
  import { createProviderSubscription } from '$lib/provider-subscription.svelte';

  // The hosting page's sign-in ceremony, offered where the lost connection is
  // noticed: the resident card. Mounted only while disconnected, so connected
  // cards make no extra requests.
  let { accountId, subscriptionAgent } = $props();
  const subscription = createProviderSubscription(() => ({ account: { id: accountId }, subscriptionAgent }));
  let agent = $derived(subscription.agent);
  let unsupported = $derived(subscription.capabilityChecked && !subscription.subscriptionSupported);
  let disabled = $derived(
    !subscription.valid || !agent.available || unsupported || subscription.mutating || subscription.connectOpen
  );

  // Once signed in, refresh the cards so the usage bars replace this button.
  let reloaded = false;
  $effect(() => {
    if (agent.connection?.status === 'connected' && !reloaded) {
      reloaded = true;
      router.reload({ only: ['agents'] });
    }
  });
</script>

<div class="mt-2 space-y-1">
  <Button type="button" size="sm" class="h-7 px-2.5 text-xs" {disabled} onclick={() => subscription.beginConnection()}>
    Reconnect
  </Button>
  {#if !agent.available}
    <p class="text-[10px]">The runtime needs to be healthy before it can be signed in again.</p>
  {:else if unsupported}
    <p class="text-[10px]">This runtime does not support subscription sign-in.</p>
  {/if}
  {#if subscription.actionError && !subscription.connectOpen}
    <p class="text-[10px] text-destructive">{subscription.actionError}</p>
  {/if}
</div>

<ProviderConnectionDialog {subscription} />
