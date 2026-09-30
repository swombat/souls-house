<script>
  import { Button } from '$lib/components/shadcn/button';
  import ProviderConnectionDialog from './provider-connection-dialog.svelte';
  import ProviderUsage from './provider-usage.svelte';
  import { createProviderSubscription } from '$lib/provider-subscription.svelte';
  let { account, subscriptionAgent, canManage = false, showAgentName = true } = $props();
  const subscription = createProviderSubscription(() => ({ account, subscriptionAgent }));
  let agent = $derived(subscription.agent);
  let capabilityChecked = $derived(subscription.capabilityChecked);
  let subscriptionSupported = $derived(subscription.subscriptionSupported);
  let isAnthropic = $derived(subscription.isAnthropic);
  let isGemini = $derived(subscription.isGemini);
  let subscriptionModeLabel = $derived(subscription.subscriptionModeLabel);
  let connectLabel = $derived(subscription.connectLabel);
  let actionError = $derived(subscription.actionError);
  let connectOpen = $derived(subscription.connectOpen);
  const setAuthMode = (...args) => subscription.setAuthMode(...args);
  const beginConnection = (...args) => subscription.beginConnection(...args);
  const disconnectSubscription = (...args) => subscription.disconnectSubscription(...args);
</script>

<div class="rounded-md border bg-muted/20 p-4">
  <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
    <div class="space-y-1">
      {#if showAgentName}
        <div class="font-medium">{agent.name}</div>
      {/if}
      <p class="text-sm text-muted-foreground">
        {agent.provider_name} · {agent.available ? 'Hosted runtime ready' : `Runtime ${agent.runtime}`}
      </p>
      {#if capabilityChecked && !subscriptionSupported}
        <p class="text-xs text-muted-foreground">
          This hosted runtime does not support
          {isAnthropic ? 'Claude Code clamping' : isGemini ? 'Antigravity clamping' : 'subscription account access'}.
        </p>
      {/if}
      {#if subscriptionSupported && agent.connection?.status === 'connected'}
        <p class="text-sm">
          Connected{agent.connection.email ? ` as ${agent.connection.email}` : ''}
          {agent.connection.plan ? ` · ${agent.connection.plan}` : ''}
        </p>
        <p class="text-xs text-muted-foreground">
          {isAnthropic
            ? 'Claude Code clamping is available; select it to draw usage from this Claude plan.'
            : isGemini
              ? 'Experimental Antigravity clamping is available; select it to draw usage from this Google AI plan.'
              : "Resident usage draws on this account's personal plan quota."}
        </p>
        <ProviderUsage {subscription} />
      {:else}
        <p class="text-xs text-muted-foreground">
          {isAnthropic
            ? 'No Claude subscription connected for clamping.'
            : isGemini
              ? 'No Google AI subscription connected through Antigravity.'
              : 'No subscription account connected.'}
        </p>
      {/if}
    </div>

    <div class="flex flex-wrap gap-2">
      <Button
        type="button"
        size="sm"
        variant={agent.auth_mode === 'api_key' ? 'default' : 'outline'}
        disabled={!canManage}
        onclick={() => setAuthMode('api_key')}>
        API key
      </Button>
      {#if agent.connection?.status === 'connected'}
        <Button
          type="button"
          size="sm"
          variant={agent.auth_mode === 'oauth_account' ? 'default' : 'outline'}
          disabled={!canManage}
          onclick={() => setAuthMode('oauth_account')}>
          {subscriptionModeLabel}
        </Button>
        <Button
          type="button"
          size="sm"
          variant="outline"
          disabled={!canManage || !agent.available}
          onclick={beginConnection}>
          Reconnect
        </Button>
        <Button
          type="button"
          size="sm"
          variant="ghost"
          disabled={!canManage || !agent.available}
          onclick={disconnectSubscription}>
          Disconnect
        </Button>
      {:else if subscriptionSupported}
        <Button type="button" size="sm" disabled={!canManage || !agent.available} onclick={beginConnection}>
          {connectLabel}
        </Button>
      {/if}
    </div>
  </div>

  {#if actionError && !connectOpen}
    <div class="mt-3 rounded-md border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
      {actionError}
    </div>
  {/if}
</div>

<ProviderConnectionDialog {subscription} />
