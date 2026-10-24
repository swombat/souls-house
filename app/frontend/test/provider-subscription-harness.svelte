<script>
  import { createProviderSubscription } from '$lib/provider-subscription.svelte';
  let { agent, account = { id: 'synthetic-account' } } = $props();
  export const subscription = createProviderSubscription(() => ({
    account,
    subscriptionAgent: agent,
  }));
</script>

<p data-testid="provider-status">{subscription.agent.connection?.status || 'none'}</p>
<p data-testid="provider-name">{subscription.agent.name}</p>
