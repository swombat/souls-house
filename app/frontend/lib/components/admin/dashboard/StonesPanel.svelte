<script>
  import GrowthChart from './GrowthChart.svelte';
  import { formatCount } from './format.js';
  import { TEAL } from './palette.js';

  let { stones } = $props();
  const namespace = $derived(stones.namespace);
  const color = $derived(namespace.percent >= 90 ? '#dc2626' : namespace.percent >= 50 ? '#f97316' : TEAL);
</script>

<section class="rounded-xl border bg-card p-5" data-testid="stones-dashboard">
  <div class="mb-4 flex flex-wrap items-baseline justify-between gap-2">
    <h2 class="font-medium">Soul stones</h2>
    <span class="text-xs text-muted-foreground">All accounts, including founding and withdrawn stones</span>
  </div>
  <div class="grid gap-6 lg:grid-cols-3">
    <div class="lg:col-span-2">
      <h3 class="mb-3 text-sm text-muted-foreground">Created stones · cumulative, last 26 weeks</h3>
      <GrowthChart weeks={stones.weeks} lines={[{ label: 'Stones', values: stones.created, color: TEAL }]} />
      <p class="mt-2 text-xs text-muted-foreground">
        {formatCount(stones.total)} retained stone records. Physically deleted stones are not included in this chart.
      </p>
    </div>
    <div>
      <h3 class="mb-3 text-sm font-medium">Hostname namespace</h3>
      <dl class="space-y-2 text-sm">
        <div class="flex justify-between">
          <dt>Used · attached to stones</dt>
          <dd>{formatCount(namespace.used)}</dd>
        </div>
        <div class="flex justify-between">
          <dt>Retired · permanently held</dt>
          <dd>{formatCount(namespace.retired)}</dd>
        </div>
        <div class="flex justify-between">
          <dt>Reserved · including retired</dt>
          <dd>{formatCount(namespace.reserved)}</dd>
        </div>
        <div class="flex justify-between">
          <dt>Capacity · 256³</dt>
          <dd>{formatCount(namespace.capacity)}</dd>
        </div>
        <div class="flex justify-between font-medium" style:color>
          <dt>Namespace reserved</dt>
          <dd>{namespace.percent.toFixed(4)}%</dd>
        </div>
      </dl>
      <div
        class="mt-3 h-2 overflow-hidden rounded-full bg-muted"
        role="progressbar"
        aria-label="Hostname namespace reserved"
        aria-valuenow={namespace.percent}
        aria-valuemin="0"
        aria-valuemax="100">
        <div class="h-full rounded-full" style:width={`${Math.min(100, namespace.percent)}%`} style:background={color}>
        </div>
      </div>
      <p class="mt-3 text-xs text-muted-foreground">Names are never reused. Orange at 50%; red at 90%.</p>
    </div>
  </div>
</section>
