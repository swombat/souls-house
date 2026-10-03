<script>
  import { Link } from '@inertiajs/svelte';
  import RhythmStateBadge from './RhythmStateBadge.svelte';
  import RhythmResidentChips from './RhythmResidentChips.svelte';
  import { formatWhen, rhythmPath } from '$lib/rhythms';

  let { rhythm, accountId } = $props();

  const nextRun = $derived(formatWhen(rhythm.next_run_at, rhythm.timezone_identifier ?? rhythm.timezone));
  const holdCount = $derived(rhythm.holds?.length ?? 0);
</script>

<Link
  href={rhythmPath(accountId, rhythm.id)}
  class="block rounded-lg border border-border bg-card p-5 transition-colors hover:bg-muted/40 focus:outline-none focus:ring-2 focus:ring-ring">
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
