<script>
  import Sparkline from './Sparkline.svelte';
  import { formatCount, formatUsd } from './format.js';
  import { CORAL, SLATE } from './palette.js';

  let { costs } = $props();
</script>

<!-- Costs -->
<div class="rounded-xl border bg-card p-5 lg:col-span-2">
  <div class="mb-4 flex items-baseline justify-between">
    <h2 class="font-medium">Model spend · {costs.window_days}d</h2>
    <span class="text-xs text-muted-foreground">estimated at list prices as of {costs.pricing_as_of}</span>
  </div>
  <div class="grid gap-4 sm:grid-cols-2">
    {#each [['public', 'New residents', CORAL], ['founding', 'Founding & family', SLATE]] as [key, title, color]}
      {@const band = costs[key]}
      <div class="rounded-lg border p-4" class:bg-muted={key === 'founding'}>
        <div class="mb-2 text-xs uppercase tracking-wide text-muted-foreground">{title}</div>
        <div class="flex items-end justify-between gap-3">
          <div>
            <div class="text-2xl font-semibold tabular-nums">{formatUsd(band.api_usd)}</div>
            <div class="text-xs text-muted-foreground">on API keys</div>
          </div>
          <Sparkline values={band.daily_usd} width={110} height={34} {color} label={`${title} daily spend`} />
        </div>
        <dl class="mt-3 space-y-1 text-sm">
          <div class="flex justify-between">
            <dt class="text-muted-foreground">Per active resident</dt>
            <dd class="tabular-nums font-medium">{formatUsd(band.per_active_resident_usd, { precise: true })}</dd>
          </div>
          <div class="flex justify-between">
            <dt class="text-muted-foreground">Active residents</dt>
            <dd class="tabular-nums">{formatCount(band.active_residents)}</dd>
          </div>
          {#if band.subscription_estimate_usd}
            <div
              class="flex justify-between"
              title="Turns on a provider subscription cost nothing extra; this is what they would have cost on an API key">
              <dt class="text-muted-foreground">Covered by subscriptions</dt>
              <dd class="tabular-nums text-muted-foreground">≈ {formatUsd(band.subscription_estimate_usd)}</dd>
            </div>
          {/if}
          {#if band.unpriced_turns}
            <div class="flex justify-between text-xs">
              <dt class="text-muted-foreground">Turns without a price</dt>
              <dd class="tabular-nums text-muted-foreground">{formatCount(band.unpriced_turns)}</dd>
            </div>
          {/if}
        </dl>
      </div>
    {/each}
  </div>
</div>
