<script>
  import Sparkline from './Sparkline.svelte';
  import { formatBytes, formatPercent } from './format.js';

  let { server, colors } = $props();

  const memUsed = $derived(
    server.mem_total_bytes && server.mem_available_bytes !== undefined
      ? server.mem_total_bytes - server.mem_available_bytes
      : null
  );
  const memShare = $derived(memUsed !== null ? memUsed / server.mem_total_bytes : null);
  const diskShare = $derived(server.disk_total_bytes ? server.disk_used_bytes / server.disk_total_bytes : null);
  const loadShare = $derived(server.cores ? (server.load?.[0] ?? 0) / server.cores : null);

  function tone(share) {
    if (share === null || share === undefined) return colors.slate;
    if (share >= 0.9) return colors.coral;
    if (share >= 0.75) return colors.amber;
    return colors.teal;
  }

  const meters = $derived([
    {
      label: server.cores ? `CPU, all ${server.cores} cores` : 'CPU',
      share: server.cpu_percent !== null && server.cpu_percent !== undefined ? server.cpu_percent / 100 : null,
      value:
        server.cpu_percent !== null && server.cpu_percent !== undefined ? `${server.cpu_percent.toFixed(0)}%` : '—',
      detail: server.cpu_avg_24h !== null ? `${server.cpu_avg_24h.toFixed(0)}% average over 24h` : 'first reading',
    },
    {
      label: 'Load',
      share: loadShare,
      value: server.load?.[0] !== undefined ? server.load[0].toFixed(2) : '—',
      detail: `${server.load?.map((v) => v?.toFixed(2)).join(' · ')} on ${server.cores} cores`,
    },
    {
      label: 'Memory',
      share: memShare,
      value: formatPercent(memShare, 0),
      detail: `${formatBytes(memUsed)} of ${formatBytes(server.mem_total_bytes)}`,
    },
    {
      label: 'Disk',
      share: diskShare,
      value: formatPercent(diskShare, 0),
      detail: `${formatBytes(server.disk_used_bytes)} of ${formatBytes(server.disk_total_bytes)}`,
    },
  ]);
</script>

<div class="grid gap-6 md:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)]">
  <div class="space-y-4">
    {#each meters as meter}
      <div>
        <div class="mb-1 flex items-baseline justify-between gap-2 text-sm">
          <span class="text-muted-foreground">{meter.label}</span>
          <span class="font-semibold tabular-nums">{meter.value}</span>
        </div>
        <div class="h-2 overflow-hidden rounded-full bg-muted">
          <div
            class="h-full rounded-full transition-all"
            style:width={`${Math.min(100, (meter.share ?? 0) * 100)}%`}
            style:background={tone(meter.share)}>
          </div>
        </div>
        <div class="mt-0.5 text-[11px] text-muted-foreground">{meter.detail}</div>
      </div>
    {/each}
  </div>
  <div class="space-y-4">
    <div>
      <div class="mb-1 flex justify-between text-xs text-muted-foreground">
        <span>CPU, hourly, last 7 days</span><span>0–100%</span>
      </div>
      <div class="w-full" style:color={colors.teal}>
        <Sparkline
          values={server.hourly_cpu}
          width={420}
          height={56}
          max={100}
          color={colors.teal}
          label="Hourly CPU"
          fluid />
      </div>
    </div>
    <div>
      <div class="mb-1 flex justify-between text-xs text-muted-foreground">
        <span>Disk used, daily, last 30 days</span><span>{formatBytes(server.disk_used_bytes)}</span>
      </div>
      <Sparkline
        values={server.daily_disk_used}
        width={420}
        height={40}
        color={colors.violet}
        label="Daily disk used"
        fluid />
    </div>
    {#if server.busiest_residents.length}
      <div>
        <div class="mb-1 text-xs text-muted-foreground">
          Busiest residents, 24h average · CPU as % of one core (100% = one busy core)
        </div>
        <ul class="space-y-1 text-sm">
          {#each server.busiest_residents as row}
            <li class="flex justify-between gap-2">
              <span class="truncate">
                {row.name}
                {#if row.founding}<span class="text-xs text-muted-foreground">founding</span>{/if}
              </span>
              <span class="tabular-nums text-muted-foreground">{row.cpu}% · {formatBytes(row.mem_bytes)}</span>
            </li>
          {/each}
        </ul>
      </div>
    {/if}
  </div>
</div>
