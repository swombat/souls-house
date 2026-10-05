<script>
  import { agentNameWithUsage, loadAgentWeeklyRemaining } from '$lib/agent-subscription-usage';

  let { accountId, agent, showUsage = false, mobileGauge = false } = $props();
  let remaining = $state(null);
  let usageIdentity;
  let label = $derived(agentNameWithUsage(agent.name, remaining, showUsage));
  let gaugeColour = $derived(
    remaining >= 50
      ? 'bg-gray-400 dark:bg-gray-500'
      : remaining >= 25
        ? 'bg-gray-600 dark:bg-gray-300'
        : remaining >= 10
          ? 'bg-amber-500'
          : 'bg-red-500'
  );

  $effect(() => {
    let cancelled = false;
    // Prop refreshes replace agent objects. Keep the existing display while
    // revalidating, but never carry usage across residents/accounts/models.
    const identity = `${accountId}:${agent.id}:${agent.model_id}`;
    if (identity !== usageIdentity) {
      usageIdentity = identity;
      remaining = null;
    }

    loadAgentWeeklyRemaining(accountId, agent).then((value) => {
      if (!cancelled) remaining = value;
    });

    return () => {
      cancelled = true;
    };
  });
</script>

{#if mobileGauge}
  <span class="hidden md:inline" aria-hidden="true">{label}</span>
  <span class="sr-only">{agent.name}{remaining === null ? '' : ` (${remaining}% left)`}</span>
  {#if remaining !== null}
    <span
      aria-hidden="true"
      data-subscription-gauge
      class="absolute right-1 top-1 bottom-1 w-1 overflow-hidden rounded-full bg-gray-200 dark:bg-gray-700 md:hidden">
      <span class="absolute bottom-0 left-0 w-full {gaugeColour}" style:height={`${remaining}%`}></span>
    </span>
  {/if}
{:else}
  {label}
{/if}
