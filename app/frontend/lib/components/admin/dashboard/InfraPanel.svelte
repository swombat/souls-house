<script>
  import { formatUsd, coverageNote } from './format.js';

  let { storage, server } = $props();
</script>

<!-- Infrastructure cost -->
<div class="rounded-xl border bg-card p-5">
  <h2 class="mb-4 font-medium">Infrastructure · per month</h2>
  <dl class="space-y-3 text-sm">
    <div class="flex justify-between gap-2">
      <dt class="text-muted-foreground">Restic on S3</dt>
      <dd class="tabular-nums font-medium">{formatUsd(storage.restic_usd_per_month, { precise: true })}</dd>
    </div>
    <div class="flex justify-between gap-2">
      <dt class="text-muted-foreground">Hetzner VMs</dt>
      <dd class="tabular-nums font-medium">
        {storage.hetzner_eur_per_month === null || storage.hetzner_eur_per_month === undefined
          ? '—'
          : `€${storage.hetzner_eur_per_month.toFixed(2)}`}
      </dd>
    </div>
    {#if server.available && server.vms?.length}
      {#each server.vms as vm}
        <div class="flex justify-between gap-2 pl-3 text-xs">
          <dt class="truncate text-muted-foreground">{vm.name ?? 'VM'} · {vm.location}</dt>
          <dd class="tabular-nums" title="Hetzner's CPU metric, averaged over the last 5 minutes">
            {vm.cpu === null ? '—' : `${vm.cpu}% (Hetzner)`}
          </dd>
        </div>
      {/each}
    {/if}
  </dl>
  <p class="mt-4 text-[11px] text-muted-foreground">
    {#if storage.s3_usd_per_gb_month}
      Restic is the S3 Standard storage run-rate at ${storage.s3_usd_per_gb_month}/GB-month
      {storage.s3_price_assumed
        ? `(assumed: no verified price for ${storage.s3_region ?? 'this region'})`
        : `(${storage.s3_region}, list price)`}, an estimate rather than the full bill: requests, transfer and anything
      outside the resident repositories aren't included.
    {:else}
      Prices arrive with the first daily storage sample.
    {/if}
    Hetzner at list price for each confirmed VM's type and location. The house host itself is a fixed cost and isn't counted.
  </p>
  {#if coverageNote(storage.restic_coverage)}
    <p class="mt-2 text-[11px] text-amber-600 dark:text-amber-400">
      Restic: {coverageNote(storage.restic_coverage)}
    </p>
  {/if}
</div>
