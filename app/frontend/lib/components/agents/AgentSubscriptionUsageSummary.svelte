<script>
  import { accountAgentProviderSubscriptionUsagePath } from '@/routes';
  import {
    displayUsageWindows,
    predictedUsage,
    usedPercent,
    predictionTone,
    resetDescription,
  } from '$lib/subscription-usage';

  let { accountId, agentId, modelId, subscription } = $props();

  let usage = $state(null);
  let loading = $state(true);
  let error = $state(false);
  let windows = $derived(displayUsageWindows(usage, subscription?.provider, modelId));
  let now = $state(Date.now());
  $effect(() => {
    const timer = setInterval(() => {
      now = Date.now();
    }, 60_000);
    return () => clearInterval(timer);
  });

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
</script>

{#if subscription?.auth_mode === 'oauth_account'}
  <div
    class="mb-4 rounded-md border px-2.5 py-2 text-xs {usage?.status === 'limited'
      ? 'border-amber-500/40 bg-amber-500/10 text-amber-800 dark:text-amber-200'
      : 'bg-muted/40 text-muted-foreground'}">
    <div
      class="font-medium mb-2"
      title="Provider subscription usage, shared with other clients using the same provider account. Not a separate allowance for this resident.">
      Shared subscription
    </div>
    {#if loading}
      Checking usage…
    {:else if error || usage?.status === 'unknown'}
      Usage unavailable
    {:else if subscription.connection?.status !== 'connected'}
      Subscription not connected
    {:else if !subscription.available || !windows.length}
      Usage unavailable
    {:else}
      {#if usage?.status === 'limited'}<div class="mb-2">Subscription limit reached</div>{/if}
      <div class="space-y-3">
        {#each windows as window}
          {@const used = usedPercent(window)}
          {@const prediction = predictedUsage(window, now)}
          {@const tone = predictionTone(prediction)}
          <div>
            <div class="flex items-center justify-between gap-2 mb-1 text-[10px]">
              <span class="font-medium">{window.displayLabel}</span>
              <span>{resetDescription(window.resets_at, now)}</span>
            </div>
            <div
              class="h-1.5 bg-muted rounded-full overflow-hidden"
              role="meter"
              aria-label={`${window.displayLabel} utilisation`}
              aria-valuenow={used ?? undefined}
              aria-valuemin="0"
              aria-valuemax="100">
              <div class="h-full bg-primary rounded-full" style:width={`${used ?? 0}%`}></div>
            </div>
            <div class="flex justify-between mt-1 text-[10px]">
              <span class="text-foreground">{used == null ? 'Unknown' : `${Math.round(used * 10) / 10}% used`}</span>
              <span
                title="Projected usage at reset at the average consumption rate so far in this window. Not a guarantee."
                class={tone === 'danger'
                  ? 'text-red-600 dark:text-red-400'
                  : tone === 'warning'
                    ? 'text-amber-700 dark:text-amber-300'
                    : 'text-sky-600 dark:text-sky-400'}>
                {prediction === null ? 'Forecast unavailable' : `${prediction}% predicted`}
              </span>
            </div>
          </div>
        {/each}
      </div>
    {/if}
  </div>
{/if}
