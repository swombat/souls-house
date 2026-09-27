<script>
  import { useSync } from '$lib/use-sync';
  import UnestimatedCosts from '$lib/components/agents/UnestimatedCosts.svelte';

  let { account, agents = [], cost_report: costReport = {} } = $props();

  useSync(Object.fromEntries(agents.map((agent) => [`Agent:${agent.id}`, 'cost_report'])));

  function dollars(value) {
    if (value === null || value === undefined) return '—';

    const amount = Number(value);
    const digits = amount < 0.01 ? 4 : 2;
    return `≈${new Intl.NumberFormat('en-US', {
      style: 'currency',
      currency: 'USD',
      minimumFractionDigits: digits,
      maximumFractionDigits: digits,
    }).format(amount)}`;
  }

  function date(value) {
    return new Intl.DateTimeFormat('en-GB', {
      dateStyle: 'medium',
      timeZone: 'UTC',
    }).format(new Date(`${value}T00:00:00Z`));
  }
</script>

<svelte:head>
  <title>Costs · {account.name}</title>
</svelte:head>

<div class="container mx-auto max-w-7xl p-8">
  <div class="mb-8">
    <h1 class="text-3xl font-bold">Costs</h1>
    <p class="mt-2 text-muted-foreground">
      Estimated interaction costs for {account.name}, grouped by day and resident. The latest 30 days with available
      estimates are shown.
    </p>
    <p class="mt-1 text-xs text-muted-foreground">
      Standard token-rate estimates, not invoices. Context/tier surcharges, tool fees and cache storage are not
      included.
    </p>
  </div>

  <UnestimatedCosts rows={costReport.unestimated} />

  {#if !costReport.total_amount_usd && !costReport.subscription_estimate_usd}
    <div class="rounded border p-8 text-center text-sm text-muted-foreground">
      No estimated interaction costs are available yet.
    </div>
  {:else}
    <div class="mb-6 rounded border bg-muted/30 p-4">
      <div class="text-sm text-muted-foreground">Estimated API-key account cost to date</div>
      <div class="mt-1 text-2xl font-semibold">{dollars(costReport.total_amount_usd)}</div>
      {#if costReport.subscription_estimate_usd}
        <div
          class="mt-1 text-sm text-muted-foreground line-through"
          title="These API-equivalent estimates do not apply because the interactions used provider subscriptions.">
          Subscription-based estimate: {dollars(costReport.subscription_estimate_usd)}
        </div>
      {/if}
      {#if costReport.pricing_as_of}
        <div class="mt-1 text-xs text-muted-foreground">Prices as of {date(costReport.pricing_as_of)}</div>
      {/if}
    </div>

    <div class="overflow-x-auto rounded border">
      <table class="min-w-full text-sm">
        <thead class="bg-muted/50 text-left">
          <tr>
            <th class="sticky left-0 bg-muted px-4 py-3 font-medium">Day</th>
            {#each costReport.agents as agent}
              <th class="px-4 py-3 text-right font-medium whitespace-nowrap">{agent.name}</th>
            {/each}
            <th class="px-4 py-3 text-right font-semibold">Total</th>
          </tr>
        </thead>
        <tbody class="divide-y">
          {#each costReport.days as day}
            <tr>
              <td class="sticky left-0 bg-background px-4 py-3 whitespace-nowrap">{date(day.date)}</td>
              {#each costReport.agents as agent}
                <td class="px-4 py-3 text-right tabular-nums">
                  <div>{dollars(day.agent_costs[agent.id])}</div>
                  {#if day.agent_subscription_estimates?.[agent.id]}
                    <div
                      class="text-xs text-muted-foreground line-through"
                      title="Subscription-based API-equivalent estimate; this cost does not apply.">
                      {dollars(day.agent_subscription_estimates[agent.id])}
                    </div>
                  {/if}
                </td>
              {/each}
              <td class="px-4 py-3 text-right font-semibold tabular-nums">{dollars(day.total_amount_usd)}</td>
            </tr>
          {/each}
        </tbody>
        <tfoot class="border-t bg-muted/30">
          <tr>
            <th class="sticky left-0 bg-muted px-4 py-3 text-left font-semibold">Total to date</th>
            {#each costReport.agents as agent}
              <td class="px-4 py-3 text-right font-semibold tabular-nums">
                <div>{dollars(costReport.agent_totals[agent.id])}</div>
                {#if costReport.agent_subscription_estimates?.[agent.id]}
                  <div
                    class="text-xs font-normal text-muted-foreground line-through"
                    title="Subscription-based API-equivalent estimate; this cost does not apply.">
                    {dollars(costReport.agent_subscription_estimates[agent.id])}
                  </div>
                {/if}
              </td>
            {/each}
            <td class="px-4 py-3 text-right font-bold tabular-nums">{dollars(costReport.total_amount_usd)}</td>
          </tr>
        </tfoot>
      </table>
    </div>
  {/if}
</div>
