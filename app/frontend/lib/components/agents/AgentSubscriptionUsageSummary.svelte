<script>
  import { accountAgentProviderSubscriptionUsagePath } from '@/routes';

  let { accountId, agentId, subscription } = $props();

  let usage = $state(null);
  let loading = $state(true);
  let error = $state(false);

  $effect(() => {
    if (
      !subscription?.available ||
      subscription.auth_mode !== 'oauth_account' ||
      subscription.connection?.status !== 'connected'
    ) {
      loading = false;
      return;
    }

    loadUsage();
  });

  async function loadUsage() {
    loading = true;
    error = false;

    try {
      const response = await fetch(accountAgentProviderSubscriptionUsagePath(accountId, agentId), {
        headers: { Accept: 'application/json' },
      });
      if (!response.ok) throw new Error('Usage unavailable');
      usage = await response.json();
    } catch {
      error = true;
    } finally {
      loading = false;
    }
  }

  function visibleWindows() {
    const windows = usage?.windows || [];
    const blocking = windows.filter((window) => window.blocking);
    return blocking.length > 0 ? blocking : windows;
  }

  function usageLine(window) {
    const remaining = Math.max(0, Math.min(100, Number(window.remaining_percent) || 0));
    const reset = resetDescription(window.resets_at);
    return `${window.label || 'Usage'} ${remaining.toFixed(remaining % 1 === 0 ? 0 : 1)}% left${reset ? `, ${reset}` : ''}`;
  }

  function limitedReset() {
    const window = visibleWindows().find((item) => Number(item.remaining_percent) <= 0);
    return resetDescription(window?.resets_at);
  }

  function resetDescription(value) {
    if (!value) return '';
    const seconds = Math.ceil((new Date(value).getTime() - Date.now()) / 1000);
    if (seconds <= 0) return 'reset pending';
    if (seconds < 3600) return `resets in ${Math.ceil(seconds / 60)}m`;
    if (seconds < 86400) {
      const hours = Math.floor(seconds / 3600);
      const minutes = Math.ceil((seconds % 3600) / 60);
      return `resets in ${hours}h${minutes ? ` ${minutes}m` : ''}`;
    }
    return `resets ${new Intl.DateTimeFormat(undefined, {
      month: 'short',
      day: 'numeric',
      hour: 'numeric',
      minute: '2-digit',
    }).format(new Date(value))}`;
  }
</script>

{#if subscription?.auth_mode === 'oauth_account'}
  <div
    class="mb-4 rounded-md border px-2.5 py-2 text-xs {usage?.status === 'limited'
      ? 'border-amber-500/40 bg-amber-500/10 text-amber-800 dark:text-amber-200'
      : 'bg-muted/40 text-muted-foreground'}">
    <span class="font-medium">{subscription.provider_name}:</span>
    {#if loading}
      checking usage…
    {:else if error || usage?.status === 'unknown'}
      usage unavailable
    {:else if usage?.status === 'limited'}
      subscription limit reached{limitedReset() ? ` · ${limitedReset()}` : ''}
    {:else}
      {visibleWindows().map(usageLine).join(' · ')}
    {/if}
  </div>
{/if}
