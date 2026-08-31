<script>
  import { accountAgentProviderSubscriptionUsagePath } from '@/routes';
  import {
    displayUsageWindows,
    predictedWeeklyUsage,
    predictionTone,
    resetDescription,
    usageLine,
  } from '$lib/subscription-usage';

  let { accountId, agentId, modelId, subscription } = $props();

  let usage = $state(null);
  let loading = $state(true);
  let error = $state(false);
  let windows = $derived(displayUsageWindows(usage, subscription?.provider, modelId));
  let prediction = $derived(predictedWeeklyUsage(windows));
  let tone = $derived(predictionTone(prediction));

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

  function limitedReset() {
    const window = windows.find((item) => Number(item.remaining_percent) <= 0);
    return resetDescription(window?.resets_at);
  }
</script>

{#if subscription?.auth_mode === 'oauth_account'}
  <div
    class="mb-4 rounded-md border px-2.5 py-2 text-xs {usage?.status === 'limited'
      ? 'border-amber-500/40 bg-amber-500/10 text-amber-800 dark:text-amber-200'
      : 'bg-muted/40 text-muted-foreground'}">
    {#if loading}
      Checking usage…
    {:else if error || usage?.status === 'unknown'}
      Usage unavailable
    {:else if usage?.status === 'limited'}
      Subscription limit reached{limitedReset() ? ` · ${limitedReset()}` : ''}
    {:else}
      <div class="space-y-0.5">
        {#each windows as window}
          <div>{usageLine(window)}</div>
        {/each}
        {#if prediction !== null}
          <div
            class={tone === 'danger'
              ? 'font-medium text-red-600 dark:text-red-400'
              : tone === 'warning'
                ? 'font-medium text-amber-700 dark:text-amber-300'
                : 'text-muted-foreground'}>
            Predicted usage: {prediction}%
          </div>
        {/if}
      </div>
    {/if}
  </div>
{/if}
