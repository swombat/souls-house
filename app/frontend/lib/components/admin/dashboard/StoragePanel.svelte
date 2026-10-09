<script>
  import Sparkline from './Sparkline.svelte';
  import { formatCount, formatUsd, formatPercent, formatBytes, coverageNote } from './format.js';
  import { TEAL, VIOLET, SLATE } from './palette.js';

  let { storage, backups } = $props();

  const dedupShare = $derived(
    storage.restic_stored_bytes && backups.logical_bytes ? storage.restic_stored_bytes / backups.logical_bytes : null
  );

  const largestBackup = $derived(Math.max(1, ...backups.largest.map((row) => row.bytes)));

  const storageRows = $derived([
    {
      label: 'On resident disks',
      bytes: storage.disk_bytes,
      daily: storage.disk_daily_bytes,
      color: TEAL,
      note:
        storage.disk_bytes === null || storage.disk_bytes === undefined
          ? 'not measured yet'
          : `${formatCount(storage.disk_residents_measured)} residents, measured hourly`,
      warning: coverageNote(storage.disk_coverage),
    },
    {
      label: 'Latest backups',
      bytes: backups.logical_bytes,
      daily: backups.daily_logical_bytes,
      color: SLATE,
      note: `${formatCount(backups.residents_backed_up)} residents' last good backup, before dedup`,
      warning: null,
    },
    {
      label: 'Stored in S3',
      bytes: storage.restic_stored_bytes,
      daily: storage.restic_daily_bytes,
      color: VIOLET,
      note: storage.restic_sampled
        ? `repositories are ${formatPercent(dedupShare, 0)} of latest backups, history included · ~${formatUsd(
            storage.restic_usd_per_month,
            { precise: true }
          )}/month`
        : 'sampled daily; first reading pending',
      warning: coverageNote(storage.restic_coverage),
    },
  ]);
</script>

<!-- Storage -->
<div class="rounded-xl border bg-card p-5 lg:col-span-2">
  <div class="mb-4 flex items-baseline justify-between">
    <h2 class="font-medium">Storage &amp; backups</h2>
    <span class="text-xs text-muted-foreground">largest backups, Restic one repository per resident</span>
  </div>
  <div class="grid gap-6 sm:grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)]">
    <div class="space-y-4">
      {#each storageRows as row}
        <div class="flex items-center justify-between gap-3">
          <div class="min-w-0">
            <div class="text-xs text-muted-foreground">{row.label}</div>
            <div class="text-xl font-semibold tabular-nums">{formatBytes(row.bytes)}</div>
            <div class="text-[11px] text-muted-foreground">{row.note}</div>
            {#if row.warning}
              <div class="text-[11px] text-amber-600 dark:text-amber-400">{row.warning}</div>
            {/if}
          </div>
          <Sparkline values={row.daily} width={120} height={34} color={row.color} label={`${row.label} per day`} />
        </div>
      {/each}
    </div>
    <ul class="space-y-2 text-sm">
      {#each backups.largest as row}
        <li>
          <div class="flex justify-between gap-2">
            <span class="truncate">
              {row.name}
              {#if row.founding}<span class="text-xs text-muted-foreground">founding</span>{/if}
            </span>
            <span class="tabular-nums text-muted-foreground">{formatBytes(row.bytes)}</span>
          </div>
          <div class="mt-1 h-1.5 rounded-full bg-muted overflow-hidden">
            <div
              class="h-full rounded-full"
              style:width={`${(row.bytes / largestBackup) * 100}%`}
              style:background={row.founding ? SLATE : VIOLET}>
            </div>
          </div>
        </li>
      {:else}
        <li class="text-muted-foreground">No successful backups yet.</li>
      {/each}
    </ul>
  </div>
</div>
