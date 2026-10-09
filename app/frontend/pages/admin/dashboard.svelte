<script>
  import { router } from '@inertiajs/svelte';
  import { ArrowClockwise, Warning } from 'phosphor-svelte';
  import StatTile from '$lib/components/admin/dashboard/StatTile.svelte';
  import Sparkline from '$lib/components/admin/dashboard/Sparkline.svelte';
  import StackedBars from '$lib/components/admin/dashboard/StackedBars.svelte';
  import GrowthChart from '$lib/components/admin/dashboard/GrowthChart.svelte';
  import {
    formatCount,
    formatUsd,
    formatPercent,
    formatBytes,
    weeklyDelta,
    periodChange,
    stackTotals,
  } from '$lib/components/admin/dashboard/format.js';

  let { dashboard, cached_for_seconds = 300 } = $props();

  // The house palette: teal for life, coral for trouble and money, slate for
  // the founding band.
  const TEAL = '#14b8a6';
  const CORAL = '#f97366';
  const VIOLET = '#8b5cf6';
  const SLATE = '#94a3b8';
  const CHANNEL_COLORS = {
    conversation: TEAL,
    telegram: '#38bdf8',
    wake: '#f59e0b',
    memory: VIOLET,
    other: SLATE,
  };

  let activityScope = $state('growth');
  let refreshing = $state(false);

  const h = $derived(dashboard.headline);
  const activity = $derived(dashboard.activity);
  const reliability = $derived(dashboard.reliability);
  const costs = $derived(dashboard.costs);
  const backups = $derived(dashboard.backups);
  const placement = $derived(dashboard.placement);
  const funnel = $derived(dashboard.funnel);

  const channelKeys = $derived(activity.channels.map((c) => c.key));
  const activitySeries = $derived(activity[activityScope]);
  const dailyTurns = $derived(stackTotals(activitySeries, channelKeys));
  const growthTurns = $derived(stackTotals(activity.growth, channelKeys));
  const turns7d = $derived(dailyTurns.slice(-7).reduce((a, b) => a + b, 0));
  const heartbeats7d = $derived((activitySeries.wake || []).slice(-7).reduce((a, b) => a + b, 0));

  const failureTone = $derived(
    reliability.failure_rate === null ? 'neutral' : reliability.failure_rate >= 0.05 ? 'alert' : 'up'
  );
  const funnelSteps = ['Signed up', 'Made a resident', 'Resident in conversation'];
  const funnelMax = $derived(Math.max(1, funnel.all_time[0]));

  const placementTotals = $derived(
    placement.groups.reduce((totals, row) => {
      const key = row.backend === 'hetzner_cloud' ? 'hetzner' : 'house';
      totals[key] = (totals[key] || 0) + row.residents;
      return totals;
    }, {})
  );
  const placementSum = $derived(Math.max(1, (placementTotals.house || 0) + (placementTotals.hetzner || 0)));
  const largestBackup = $derived(Math.max(1, ...backups.largest.map((row) => row.bytes)));

  const generated = $derived(
    new Date(dashboard.generated_at).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })
  );

  function refresh() {
    refreshing = true;
    router.visit('/admin/dashboard?refresh=1', { preserveScroll: true, onFinish: () => (refreshing = false) });
  }

  function unmarkFounding(account) {
    if (!confirm(`Count ${account.name} as a normal account in the growth numbers?`)) return;
    router.patch(`/admin/accounts/${account.id}/founding`, { account: { founding: false } }, { preserveScroll: true });
  }

  function backendLabel(row) {
    if (row.backend === 'hetzner_cloud') return `Hetzner${row.location ? ` · ${row.location}` : ''}`;
    return 'House host';
  }
</script>

<svelte:head><title>House at a glance · Site Admin</title></svelte:head>

<div class="mx-auto max-w-7xl px-4 py-6 sm:px-6 lg:py-8 space-y-6" data-testid="site-dashboard">
  <header class="flex flex-wrap items-end justify-between gap-3">
    <div>
      <h1 class="text-2xl font-semibold tracking-tight">House at a glance</h1>
      <p class="text-sm text-muted-foreground">
        Growth numbers leave out the {formatCount(h.founding.accounts)} founding and family accounts ({formatCount(
          h.founding.residents
        )} residents), which are costed separately below.
      </p>
    </div>
    <button
      class="inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs text-muted-foreground hover:bg-muted"
      onclick={refresh}
      disabled={refreshing}
      title={`Figures are cached for ${Math.round(cached_for_seconds / 60)} minutes`}>
      <ArrowClockwise class={refreshing ? 'size-3.5 animate-spin' : 'size-3.5'} />
      As of {generated}
    </button>
  </header>

  <!-- Headline row -->
  <section class="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
    <StatTile
      label="Accounts"
      value={formatCount(h.accounts.value)}
      detail={weeklyDelta(h.accounts.added) ?? 'none new this week'}
      tone={h.accounts.added ? 'up' : 'neutral'}
      spark={dashboard.growth.accounts} />
    <StatTile
      label="Humans"
      value={formatCount(h.humans.value)}
      detail={weeklyDelta(h.humans.added) ?? 'none new this week'}
      tone={h.humans.added ? 'up' : 'neutral'}
      spark={dashboard.growth.humans}
      sparkColor="#0ea5e9" />
    <StatTile
      label="Residents"
      value={formatCount(h.residents.value)}
      detail={weeklyDelta(h.residents.added) ?? 'none new this week'}
      tone={h.residents.added ? 'up' : 'neutral'}
      spark={dashboard.growth.residents}
      sparkColor={VIOLET} />
    <StatTile
      label="Active residents · 7d"
      value={formatCount(h.active_residents.value)}
      detail={periodChange(h.active_residents.value, h.active_residents.previous)?.label}
      tone={{ up: 'up', down: 'down', flat: 'neutral' }[
        periodChange(h.active_residents.value, h.active_residents.previous)?.direction
      ] ?? 'neutral'}
      hint="Residents with at least one turn in the last 7 days" />
    <StatTile
      label="Turns · 7d"
      value={formatCount(growthTurns.slice(-7).reduce((a, b) => a + b, 0))}
      detail={`${formatCount(h.active_humans.value)} humans talking`}
      spark={growthTurns}
      hint="Turns by non-founding residents" />
    <StatTile
      label="Failure rate · 7d"
      value={formatPercent(reliability.failure_rate)}
      detail={`${formatCount(reliability.turns_failed)} of ${formatCount(reliability.turns_finished)} turns`}
      tone={failureTone}
      spark={reliability.failure_rate_daily}
      sparkColor={CORAL}
      hint="Turns that ended in error or timeout, all residents" />
  </section>

  <section class="grid gap-4 lg:grid-cols-3">
    <!-- Growth -->
    <div class="rounded-xl border bg-card p-5 lg:col-span-2">
      <div class="mb-4 flex items-baseline justify-between">
        <h2 class="font-medium">Growth</h2>
        <span class="text-xs text-muted-foreground">cumulative, last 26 weeks</span>
      </div>
      <GrowthChart
        weeks={dashboard.growth.weeks}
        lines={[
          { label: 'Accounts', values: dashboard.growth.accounts, color: TEAL },
          { label: 'Humans', values: dashboard.growth.humans, color: '#0ea5e9' },
          { label: 'Residents', values: dashboard.growth.residents, color: VIOLET },
        ]} />
    </div>

    <!-- Funnel -->
    <div class="rounded-xl border bg-card p-5">
      <div class="mb-4 flex items-baseline justify-between">
        <h2 class="font-medium">Signup funnel</h2>
        <span class="text-xs text-muted-foreground">all time · last 30d</span>
      </div>
      <ol class="space-y-4">
        {#each funnelSteps as step, i}
          <li>
            <div class="mb-1 flex justify-between text-sm">
              <span>{step}</span>
              <span class="tabular-nums">
                <span class="font-medium">{formatCount(funnel.all_time[i])}</span>
                <span class="text-muted-foreground"> · {formatCount(funnel.last_30_days[i])}</span>
              </span>
            </div>
            <div class="h-2.5 rounded-full bg-muted overflow-hidden">
              <div
                class="h-full rounded-full"
                style:width={`${(funnel.all_time[i] / funnelMax) * 100}%`}
                style:background={TEAL}
                style:opacity={1 - i * 0.22}>
              </div>
            </div>
            {#if i > 0 && funnel.all_time[i - 1]}
              <div class="mt-1 text-[11px] text-muted-foreground">
                {formatPercent(funnel.all_time[i] / funnel.all_time[i - 1], 0)} of the step before
              </div>
            {/if}
          </li>
        {/each}
      </ol>
    </div>

    <!-- Activity -->
    <div class="rounded-xl border bg-card p-5 lg:col-span-2">
      <div class="mb-4 flex flex-wrap items-baseline justify-between gap-2">
        <h2 class="font-medium">Resident activity</h2>
        <div class="flex items-center gap-1 rounded-full border p-0.5 text-xs">
          {#each [['growth', 'New residents'], ['everyone', 'Everyone']] as [key, label]}
            <button
              class="rounded-full px-2.5 py-0.5"
              class:bg-muted={activityScope === key}
              class:font-medium={activityScope === key}
              onclick={() => (activityScope = key)}>{label}</button>
          {/each}
        </div>
      </div>
      <StackedBars days={activity.days} series={activitySeries} channels={activity.channels} colors={CHANNEL_COLORS} />
      <div class="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted-foreground">
        {#each activity.channels as channel}
          <span class="flex items-center gap-1.5">
            <span class="size-2 rounded-full" style:background={CHANNEL_COLORS[channel.key]}></span>{channel.label}
          </span>
        {/each}
        <span class="ml-auto tabular-nums"
          >{formatCount(turns7d)} turns · {formatCount(heartbeats7d)} heartbeats this week</span>
      </div>
    </div>

    <!-- Reliability -->
    <div class="rounded-xl border bg-card p-5">
      <h2 class="mb-4 font-medium">Reliability · 7d</h2>
      <dl class="space-y-3 text-sm">
        <div class="flex justify-between">
          <dt class="text-muted-foreground">Turns failed</dt>
          <dd class="tabular-nums" class:text-rose-600={reliability.turns_failed > 0}>
            {formatCount(reliability.turns_failed)}
          </dd>
        </div>
        {#each Object.entries(reliability.failures_by_kind) as [kind, count]}
          <div class="flex justify-between pl-3 text-xs">
            <dt class="flex items-center gap-1.5 text-muted-foreground">
              <span class="size-1.5 rounded-full" style:background={CHANNEL_COLORS[kind]}></span>
              {activity.channels.find((c) => c.key === kind)?.label ?? kind}
            </dt>
            <dd class="tabular-nums">{formatCount(count)}</dd>
          </div>
        {/each}
        <div class="flex justify-between">
          <dt class="text-muted-foreground">Backups failed</dt>
          <dd class="tabular-nums" class:text-rose-600={reliability.backups_failed > 0}>
            {formatCount(reliability.backups_failed)} of {formatCount(reliability.backups_taken)}
          </dd>
        </div>
        <div class="flex justify-between gap-3">
          <dt class="text-muted-foreground">Oldest open backup failure</dt>
          <dd class="text-right">
            {#if reliability.oldest_open_failure_at}
              <span class="inline-flex items-center gap-1 text-rose-600">
                <Warning class="size-3.5" />
                {new Date(reliability.oldest_open_failure_at).toLocaleString('en-GB', {
                  dateStyle: 'medium',
                  timeStyle: 'short',
                })}
              </span>
            {:else}
              <span class="text-teal-600 dark:text-teal-400">none</span>
            {/if}
          </dd>
        </div>
      </dl>
    </div>

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

    <!-- Placement -->
    <div class="rounded-xl border bg-card p-5">
      <h2 class="mb-4 font-medium">Where residents live</h2>
      <div class="mb-3 flex h-3 overflow-hidden rounded-full bg-muted">
        <div style:width={`${((placementTotals.house || 0) / placementSum) * 100}%`} style:background={TEAL}></div>
        <div style:width={`${((placementTotals.hetzner || 0) / placementSum) * 100}%`} style:background={VIOLET}></div>
      </div>
      <ul class="space-y-1.5 text-sm">
        {#each placement.groups as row}
          <li class="flex justify-between gap-2">
            <span class="flex items-center gap-1.5">
              <span class="size-2 rounded-full" style:background={row.backend === 'hetzner_cloud' ? VIOLET : TEAL}
              ></span>
              {backendLabel(row)}
              {#if row.founding}<span class="text-xs text-muted-foreground">founding</span>{/if}
            </span>
            <span class="tabular-nums">{formatCount(row.residents)}</span>
          </li>
        {:else}
          <li class="text-sm text-muted-foreground">No residents yet.</li>
        {/each}
      </ul>
      {#if placement.vms.length}
        <div class="mt-4 border-t pt-3 text-xs text-muted-foreground">
          Hetzner VMs:
          {placement.vms.map((vm) => `${vm.count} × ${vm.server_type} (${vm.location})`).join(', ')}
        </div>
      {/if}
    </div>

    <!-- Storage -->
    <div class="rounded-xl border bg-card p-5 lg:col-span-2">
      <div class="mb-4 flex items-baseline justify-between">
        <h2 class="font-medium">Backups</h2>
        <span class="text-xs text-muted-foreground">Restic, one repository per resident</span>
      </div>
      <div class="grid gap-6 sm:grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)]">
        <div>
          <div class="text-2xl font-semibold tabular-nums">{formatBytes(backups.logical_bytes)}</div>
          <div class="text-xs text-muted-foreground">
            backed up across {formatCount(backups.residents_backed_up)} residents
          </div>
          <div class="mt-3">
            <Sparkline
              values={backups.daily_logical_bytes}
              width={220}
              height={44}
              color={VIOLET}
              label="Backed-up bytes per day" />
          </div>
          <p class="mt-3 text-xs text-muted-foreground">
            This is the data each resident had at its last backup. What S3 actually stores after deduplication, and what
            it costs, arrives with the storage sampler.
          </p>
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

    <!-- Founding -->
    <div class="rounded-xl border bg-card p-5">
      <h2 class="mb-1 font-medium">Founding & family</h2>
      <p class="mb-3 text-xs text-muted-foreground">Left out of growth. Mark more from Manage Accounts.</p>
      <ul class="max-h-64 space-y-1 overflow-y-auto text-sm">
        {#each dashboard.founding as account (account.id)}
          <li class="group flex items-center justify-between gap-2">
            <span class="truncate">{account.name}</span>
            <span class="flex items-center gap-2">
              <span class="tabular-nums text-xs text-muted-foreground">{account.residents} res.</span>
              <button
                class="text-xs text-muted-foreground opacity-0 group-hover:opacity-100 hover:text-foreground"
                onclick={() => unmarkFounding(account)}>unmark</button>
            </span>
          </li>
        {:else}
          <li class="text-muted-foreground">None marked.</li>
        {/each}
      </ul>
    </div>
  </section>
</div>
