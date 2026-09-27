<script>
  import UnestimatedCosts from './UnestimatedCosts.svelte';

  let { report = {} } = $props();

  function dollars(value) {
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

<div class="space-y-5">
  <div>
    <h2 class="text-xl font-semibold">Costs</h2>
    <p class="text-sm text-muted-foreground">
      Estimated interaction costs grouped by day. Only interactions with available usage telemetry and configured prices
      are included. The latest 30 days with estimates are shown.
    </p>
    <p class="mt-1 text-xs text-muted-foreground">
      Standard token-rate estimates, not invoices. Context/tier surcharges, tool fees and cache storage are not
      included.
    </p>
  </div>

  <UnestimatedCosts rows={report.unestimated} />

  {#if !report.total_amount_usd && !report.subscription_estimate_usd}
    <div class="rounded border p-8 text-center text-sm text-muted-foreground">
      No estimated interaction costs are available yet.
    </div>
  {:else}
    <div class="rounded border bg-muted/30 p-4">
      <div class="text-sm text-muted-foreground">Estimated API-key cost to date</div>
      <div class="mt-1 text-2xl font-semibold">{dollars(report.total_amount_usd)}</div>
      {#if report.subscription_estimate_usd}
        <div
          class="mt-1 text-sm text-muted-foreground line-through"
          title="These API-equivalent estimates do not apply because the interactions used a provider subscription.">
          Subscription-based estimate: {dollars(report.subscription_estimate_usd)}
        </div>
      {/if}
      <div class="mt-1 text-xs text-muted-foreground">
        {report.interaction_count} priced interaction{report.interaction_count === 1 ? '' : 's'}
        {#if report.pricing_as_of}
          · prices as of {date(report.pricing_as_of)}
        {/if}
      </div>
    </div>

    <div class="overflow-hidden rounded border">
      <table class="w-full text-sm">
        <thead class="bg-muted/50 text-left">
          <tr>
            <th class="px-4 py-3 font-medium">Day</th>
            <th class="px-4 py-3 text-right font-medium">Interactions</th>
            <th class="px-4 py-3 text-right font-medium">Estimated cost</th>
          </tr>
        </thead>
        <tbody class="divide-y">
          {#each report.days as day}
            <tr>
              <td class="px-4 py-3">{date(day.date)}</td>
              <td class="px-4 py-3 text-right tabular-nums">{day.interaction_count}</td>
              <td class="px-4 py-3 text-right font-medium tabular-nums">
                <div>{dollars(day.amount_usd)}</div>
                {#if day.subscription_estimate_usd}
                  <div
                    class="text-xs font-normal text-muted-foreground line-through"
                    title="Subscription-based API-equivalent estimate; this cost does not apply.">
                    {dollars(day.subscription_estimate_usd)}
                  </div>
                {/if}
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}
</div>
