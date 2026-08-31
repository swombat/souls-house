<script>
  import { onMount } from 'svelte';
  import { router } from '@inertiajs/svelte';
  import { ArrowClockwise } from 'phosphor-svelte';
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Button } from '$lib/components/shadcn/button';

  let { report } = $props();

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

  function timestamp(value) {
    if (!value) return 'unknown';
    return new Intl.DateTimeFormat('en-GB', {
      dateStyle: 'medium',
      timeStyle: 'short',
      timeZone: report.time_zone,
    }).format(new Date(value));
  }

  function relativeTime(value) {
    if (!value) return 'unknown';
    const seconds = Math.max(0, Math.round((new Date(report.generated_at) - new Date(value)) / 1000));
    if (seconds < 60) return 'just now';
    if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
    if (seconds < 86_400) return `${Math.floor(seconds / 3600)}h ago`;
    return `${Math.floor(seconds / 86_400)}d ago`;
  }

  function duration(value) {
    if (value == null) return 'unknown';
    if (value < 60_000) return `${Math.max(1, Math.round(value / 1000))}s`;
    if (value < 3_600_000) return `${Math.round(value / 60_000)}m`;
    return `${(value / 3_600_000).toFixed(1)}h`;
  }

  function chartHeight(value) {
    const maximum = Math.max(1, ...report.activity.days.map((day) => day.interactions));
    return value === 0 ? 0 : Math.max(8, Math.round((value / maximum) * 100));
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

  function statusClass(status) {
    if (status === 'running')
      return 'border-green-300 bg-green-50 text-green-800 dark:border-green-900 dark:bg-green-950 dark:text-green-300';
    if (status === 'failed')
      return 'border-red-300 bg-red-50 text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300';
    if (status === 'stale')
      return 'border-amber-300 bg-amber-50 text-amber-800 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-300';
    return 'border-border bg-muted/50 text-muted-foreground';
  }

  function statusLabel(status) {
    return { running: 'Running now', failed: 'Failed', stale: 'Possibly interrupted', completed: 'Completed' }[status];
  }

  function detailsPath(session) {
    const query = new URLSearchParams({
      session_id: session.session_id,
      from: report.window_started_at,
      to: report.generated_at,
    });
    return `/admin/agents/${session.resident.id}/runtime?${query}`;
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
      <CardDescription>Each bar is the number of resident runtime interactions started that day.</CardDescription>
    </CardHeader>
    <CardContent>
      <div class="grid h-64 grid-cols-7 gap-2 sm:gap-4">
        {#each report.activity.days as day}
          <div class="flex min-w-0 flex-col items-center gap-2">
            <div class="flex w-full flex-1 items-end justify-center rounded bg-muted/30 px-1">
              <div
                class="group relative w-full max-w-20 rounded-t bg-primary/75 transition-colors hover:bg-primary"
                style={`height: ${chartHeight(day.interactions)}%`}
                title={`${day.interactions} interactions · ${day.sessions} sessions · ${day.residents} residents · ${channelBreakdown(day.channels)}`}>
                {#if day.interactions > 0}
                  <span class="absolute -top-6 left-1/2 -translate-x-1/2 text-xs font-medium">
                    {number(day.interactions)}
                  </span>
                {/if}
              </div>
            </div>
            <div class="text-center">
              <div class="text-xs font-medium">{day.label}</div>
              <div class="text-[11px] text-muted-foreground">{day.date.slice(5)}</div>
            </div>
          </div>
        {/each}
      </div>
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
      {#if report.sessions.length === 0}
        <p class="py-8 text-center text-sm text-muted-foreground">No resident sessions in this window.</p>
      {:else}
        <div class="overflow-x-auto">
          <table class="w-full min-w-[1050px] text-left text-sm">
            <thead class="border-b text-xs text-muted-foreground">
              <tr>
                <th class="px-3 py-2">Resident</th>
                <th class="px-3 py-2">Channel / context</th>
                <th class="px-3 py-2">Status</th>
                <th class="px-3 py-2">Last active</th>
                <th class="px-3 py-2">Activity</th>
                <th class="px-3 py-2">Runtime</th>
                <th class="px-3 py-2"></th>
              </tr>
            </thead>
            <tbody>
              {#each report.sessions as session}
                <tr class="border-b align-top last:border-0">
                  <td class="px-3 py-3">
                    <div class="font-medium">{session.resident.name}</div>
                    <div class="text-xs text-muted-foreground">{session.resident.account_name}</div>
                  </td>
                  <td class="px-3 py-3">
                    <div>{session.channel_label}</div>
                    <div class="max-w-64 truncate text-xs text-muted-foreground">
                      {session.conversation_title || session.session_id}
                    </div>
                  </td>
                  <td class="px-3 py-3">
                    <span class={`inline-flex rounded border px-2 py-0.5 text-xs ${statusClass(session.status)}`}>
                      {statusLabel(session.status)}
                    </span>
                    {#if session.latest_outcome}
                      <div class="mt-1 text-xs text-muted-foreground">{session.latest_outcome}</div>
                    {/if}
                  </td>
                  <td class="px-3 py-3">
                    <div>{relativeTime(session.last_observed_at)}</div>
                    <div class="text-xs text-muted-foreground">{timestamp(session.last_observed_at)}</div>
                  </td>
                  <td class="px-3 py-3">
                    <div>{session.interaction_count} interaction{session.interaction_count === 1 ? '' : 's'}</div>
                    <div class="text-xs text-muted-foreground">
                      {duration(session.active_duration_ms)} span · {session.chaos_process_count} process{session.chaos_process_count ===
                      1
                        ? ''
                        : 'es'}
                    </div>
                  </td>
                  <td class="px-3 py-3">
                    <div>{session.provider || 'unknown'}</div>
                    <div class="max-w-56 truncate text-xs text-muted-foreground">
                      {session.model || session.resident.runtime}
                    </div>
                  </td>
                  <td class="px-3 py-3 text-right">
                    <Button variant="outline" size="sm" onclick={() => router.visit(detailsPath(session))}
                      >Details</Button>
                  </td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      {/if}
    </CardContent>
  </Card>
</div>
