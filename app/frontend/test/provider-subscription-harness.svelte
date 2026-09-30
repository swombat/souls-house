<script>
  import { createProviderSubscription } from '$lib/provider-subscription.svelte';
  let { agent } = $props();
  export const subscription = createProviderSubscription(() => ({
    account: { id: 'synthetic-account' },
    subscriptionAgent: agent,
  }));
</script>
