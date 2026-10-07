<script>
  import { Link } from '@inertiajs/svelte';
  import RhythmStateBadge from './RhythmStateBadge.svelte';
  import RhythmResidentChips from './RhythmResidentChips.svelte';
  import { formatWhen, rhythmPath } from '$lib/rhythms';

  let { rhythm, accountId } = $props();

  const zone = $derived(rhythm.timezone_identifier ?? rhythm.timezone);
  const nextRun = $derived(formatWhen(rhythm.next_run_at, zone));
  const holdCount = $derived(rhythm.holds?.length ?? 0);
  const recentRuns = $derived(rhythm.recent_runs ?? []);
  const headerCorners = $derived(recentRuns.length > 0 ? 'rounded-t-lg' : 'rounded-lg');
</script>

<div class="rounded-lg border border-border bg-card" data-testid="rhythm-card">
  <Link
    href={rhythmPath(accountId, rhythm.id)}
    class="block p-5 transition-colors hover:bg-muted/40 focus:outline-none focus:ring-2 focus:ring-ring {headerCorners}">
    <div class="flex items-start justify-between gap-4">
      <div class="min-w-0">
        <h2 class="truncate text-lg font-semibold">{rhythm.title}</h2>
        <p class="mt-0.5 text-sm text-muted-foreground">{rhythm.schedule_description}</p>
      </div>
      <RhythmStateBadge state={rhythm.state} {holdCount} />
    </div>

    <div class="mt-4 flex flex-wrap items-center gap-x-4 gap-y-2 text-sm">
      <RhythmResidentChips residents={rhythm.residents} />
      <span class="text-muted-foreground">Set up by {rhythm.creator?.name}</span>
    </div>

    <p class="mt-3 text-xs text-muted-foreground">
      {#if rhythm.state === 'paused'}
        Paused by {rhythm.holds?.map((hold) => hold.holder_name).join(', ')}
      {:else if nextRun}
        Next: {nextRun}
      {/if}
    </p>
  </Link>

  {#if recentRuns.length > 0}
    <ul class="divide-y divide-border border-t border-border text-sm" aria-label="Recent conversations">
      {#each recentRuns as run (run.id)}
        <li>
          <Link
            href={run.chat_url}
            class="flex items-center justify-between gap-4 px-5 py-2 transition-colors hover:bg-muted/40 focus:outline-none focus:ring-2 focus:ring-ring">
            <span class="min-w-0 truncate">{run.title}</span>
            <span class="flex shrink-0 items-center gap-2 text-xs text-muted-foreground">
              {#if run.listed}<span
                  class="rounded bg-muted px-1.5"
                  title="This conversation is in your conversation list">in your list</span
                >{/if}
              <span>{formatWhen(run.scheduled_for, zone, { withYear: false })}</span>
            </span>
          </Link>
        </li>
      {/each}
    </ul>
  {/if}
</div>
