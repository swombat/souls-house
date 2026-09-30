<script>
  import ActivityBars from '$lib/components/charts/activity-bars.svelte';
  import RuntimeSessionsTable from '$lib/components/admin/runtime-sessions-table.svelte';
  import { onMount } from 'svelte';
  import { router } from '@inertiajs/svelte';
  import { ArrowClockwise } from 'phosphor-svelte';
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Button } from '$lib/components/shadcn/button';

  let { report } = $props();

  const activityGroups = $derived(
    report.activity.days.map((day) => ({
      key: day.date,
      day,
      bars: day.buckets.map((bucket) => ({
        title: `${day.label} ${day.date.slice(5)} ${bucket.label}–${String((Number(bucket.label.slice(0, 2)) + 2) % 24).padStart(2, '0')}:00 · ${bucket.interactions} interactions · ${bucket.sessions} sessions · ${bucket.residents} residents · ${channelBreakdown(bucket.channels)}`,
        segments: [
          { value: bucket.interactions, colour: 'rounded-t-sm bg-primary/75 transition-colors hover:bg-primary' },
        ],
      })),
    }))
  );
  onMount(() => {
    const interval = setInterval(() => router.reload({ only: ['report'], preserveScroll: true }), 60_000);
    return () => clearInterval(interval);
  });

  function setWindow(window) {
    router.get(location.pathname, compact({ window, channel: report.selected_channel }), {
      preserveScroll: true,
      preserveState: false,
    });
  }

  function setChannel(event) {
    router.get(location.pathname, compact({ window: report.window, channel: event.currentTarget.value }), {
      preserveScroll: true,
      preserveState: false,
    });
  }

  function refresh() {
    router.reload({ only: ['report'], preserveScroll: true });
  }

  function compact(values) {
    return Object.fromEntries(Object.entries(values).filter(([, value]) => value));
  }

  function number(value) {
    return new Intl.NumberFormat('en-US').format(value || 0);
  }

  function channelBreakdown(channels) {
    const labels = {
      web: 'web',
      telegram: 'Telegram',
      wake: 'wake',
      orientation: 'orientation',
      memory: 'memory',
      other: 'other',
    };
    const values = Object.entries(channels || {});
    return values.length ? values.map(([key, value]) => `${labels[key]} ${value}`).join(' · ') : 'No activity';
  }
</script>

<svelte:head>
  <title>Resident sessions</title>
</svelte:head>

<div class="container mx-auto max-w-[1600px] space-y-6 px-4 py-8">
  <div class="flex flex-wrap items-start justify-between gap-4">
    <div>
      <p class="text-sm text-muted-foreground">Site administration</p>
      <h1 class="text-2xl font-bold">Resident sessions</h1>
      <p class="mt-1 text-sm text-muted-foreground">
        Runtime activity across every resident and channel. Times use {report.time_zone}.
      </p>
    </div>
    <Button variant="outline" size="sm" onclick={refresh}>
      <ArrowClockwise class="mr-2 size-4" />
      Refresh
    </Button>
  </div>

  <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
    <Card>
      <CardHeader class="pb-2"><CardDescription>Running now</CardDescription></CardHeader>
      <CardContent class="text-3xl font-semibold">{number(report.summary.running_sessions)}</CardContent>
    </Card>
    <Card>
      <CardHeader class="pb-2"><CardDescription>Active residents</CardDescription></CardHeader>
      <CardContent class="text-3xl font-semibold">{number(report.summary.active_residents)}</CardContent>
    </Card>
    <Card>
      <CardHeader class="pb-2"><CardDescription>Sessions in window</CardDescription></CardHeader>
      <CardContent class="text-3xl font-semibold">{number(report.summary.sessions)}</CardContent>
    </Card>
    <Card>
      <CardHeader class="pb-2"><CardDescription>Interactions in window</CardDescription></CardHeader>
      <CardContent>
        <div class="text-3xl font-semibold">{number(report.summary.interactions)}</div>
        {#if report.summary.busy_retries > 0}
          <div class="mt-1 text-xs text-muted-foreground">
            {number(report.summary.busy_retries)} busy retries excluded
          </div>
        {/if}
      </CardContent>
    </Card>
  </div>

  <Card>
    <CardHeader>
      <CardTitle>Last seven days</CardTitle>
      <CardDescription>Each narrow bar is a two-hour block, with 12 bars per local calendar day.</CardDescription>
    </CardHeader>
    <CardContent>
      <ActivityBars
        groups={activityGroups}
        class="h-64"
        minimumHeight={4}
        label="Runtime activity over the last seven days; two-hour buckets">
        {#snippet footer(group)}
          <div class="text-center">
            <div class="text-xs font-medium">{group.day.label}</div>
            <div class="text-[11px] text-muted-foreground">
              {group.day.date.slice(5)} · {number(group.day.interactions)}
            </div>
          </div>
        {/snippet}
      </ActivityBars>
      <p class="mt-4 text-xs text-muted-foreground">Hover a bar for its sessions, residents, and channel breakdown.</p>
    </CardContent>
  </Card>

  <Card>
    <CardHeader>
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div>
          <CardTitle>Recent sessions</CardTitle>
          <CardDescription>
            Grouped by resident and logical session. This page refreshes automatically once a minute.
          </CardDescription>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <select
            class="h-9 rounded-md border bg-background px-3 text-sm"
            value={report.selected_channel || ''}
            onchange={setChannel}
            aria-label="Filter by channel">
            <option value="">All channels</option>
            {#each report.channel_options as option}
              <option value={option.value}>{option.label}</option>
            {/each}
          </select>
          <div class="flex rounded-md border p-0.5">
            {#each [['1h', '1 hour'], ['24h', '24 hours'], ['7d', '7 days']] as [value, label]}
              <Button
                size="sm"
                variant={report.window === value ? 'secondary' : 'ghost'}
                onclick={() => setWindow(value)}>
                {label}
              </Button>
            {/each}
          </div>
        </div>
      </div>
    </CardHeader>
    <CardContent>
      <RuntimeSessionsTable {report} />
    </CardContent>
  </Card>
</div>
