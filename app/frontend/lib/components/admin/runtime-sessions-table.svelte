<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button';
  let { report } = $props();
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

  function estimatedCost(cost) {
    if (!cost?.amount_usd) return 'Unavailable';

    const amount = Number(cost.amount_usd);
    const maximumFractionDigits = amount >= 1 ? 2 : amount >= 0.01 ? 3 : 4;
    return new Intl.NumberFormat('en-US', {
      style: 'currency',
      currency: 'USD',
      minimumFractionDigits: 2,
      maximumFractionDigits,
    }).format(amount);
  }

  function costNote(cost) {
    if (!cost) return '';
    const notes = [];
    if (cost.basis === 'subscription_equivalent') notes.push('list-price equivalent');
    if (cost.basis === 'mixed') notes.push('mixed billing');
    if (cost.status === 'partial') notes.push(`${cost.priced_interactions}/${cost.interaction_count} priced`);
    return notes.join(' · ');
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

{#if report.sessions.length === 0}
  <p class="py-8 text-center text-sm text-muted-foreground">No resident sessions in this window.</p>
{:else}
  <div class="overflow-x-auto">
    <table class="w-full min-w-[1180px] text-left text-sm">
      <thead class="border-b text-xs text-muted-foreground">
        <tr>
          <th class="px-3 py-2">Resident</th>
          <th class="px-3 py-2">Channel / context</th>
          <th class="px-3 py-2">Status</th>
          <th class="px-3 py-2">Last active</th>
          <th class="px-3 py-2">Activity</th>
          <th class="px-3 py-2">Runtime</th>
          <th class="px-3 py-2">Estimated cost</th>
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
            <td class="px-3 py-3">
              <div>{estimatedCost(session.estimated_cost)}</div>
              {#if costNote(session.estimated_cost)}
                <div class="text-xs text-muted-foreground">{costNote(session.estimated_cost)}</div>
              {/if}
            </td>
            <td class="px-3 py-3 text-right">
              <Button variant="outline" size="sm" onclick={() => router.visit(detailsPath(session))}>Details</Button>
            </td>
          </tr>
        {/each}
      </tbody>
    </table>
  </div>
{/if}
