<script>
  import { siteName } from '$lib/branding';
  import AgentProviderSubscriptionPanel from './AgentProviderSubscriptionPanel.svelte';

  let { account, providerSubscription, canManageProviderSubscription = false } = $props();
</script>

<div class="border rounded-lg p-6 space-y-3">
  <div class="space-y-1">
    {#if providerSubscription.provider === 'anthropic'}
      <h2 class="text-lg font-semibold">Claude Code clamping</h2>
      <p class="text-sm text-muted-foreground">
        Connect this resident to a personal Claude subscription and choose the Claude Code clamp instead of metered
        Anthropic API billing. Chaos runs Claude Code inside the resident's hosted runtime; if the subscription is
        unavailable, the request fails rather than falling back to the API key.
      </p>
    {:else}
      <h2 class="text-lg font-semibold">Provider subscription account</h2>
      <p class="text-sm text-muted-foreground">
        Choose whether this resident uses an API key or a personal provider subscription. Provider tokens stay inside
        the resident's private runtime state volume and are never stored by {$siteName}.
      </p>
    {/if}
  </div>
  <AgentProviderSubscriptionPanel
    {account}
    subscriptionAgent={providerSubscription}
    canManage={canManageProviderSubscription}
    showAgentName={false} />
</div>
