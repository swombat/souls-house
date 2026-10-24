<script>
  import { router } from '@inertiajs/svelte';

  let { interval_minutes = 0, waking = false, outcome = null, counts = {}, sweeps = [] } = $props();

  const outcomes = [
    { value: null, label: 'All' },
    { value: 'would_wake', label: 'Would wake' },
    { value: 'person_holds', label: 'Waiting on a person' },
    { value: 'quiet', label: 'Nothing to do' },
    { value: 'error', label: 'Error' },
  ];

  function show(value) {
    router.get('/admin/stalled_sweeps', value ? { outcome: value } : {}, { preserveScroll: true });
  }

  const percent = (score) => (score == null ? '–' : `${Math.round(score * 100)}%`);
</script>

<svelte:head><title>Stalled threads</title></svelte:head>

<div class="mx-auto max-w-6xl space-y-6 p-6">
  <h1 class="text-2xl font-semibold">Stalled threads</h1>
  <p>
    {#if interval_minutes > 0}
      Rooms quiet for {interval_minutes} minutes are judged once per state.
      {#if waking}Waking is on: a resident judged to have a step is woken once per stretch between a person's messages.{:else}Shadow
        mode: nothing is posted and nobody is woken; these rows are what the sweeper would have done.{/if}
    {:else}
      The sweeper is off (Site Settings). Earlier verdicts stay listed.
    {/if}
  </p>
  <p class="text-sm text-muted-foreground">
    Last 7 days: {counts.would_wake || 0} would wake · {counts.person_holds || 0} waiting on a person ·
    {counts.quiet || 0} nothing to do · {counts.error || 0} errors.
  </p>

  <div role="radiogroup" aria-label="Outcome" class="inline-flex gap-1 rounded-md border p-1">
    {#each outcomes as option}
      <button
        type="button"
        role="radio"
        aria-checked={outcome === option.value}
        class="rounded px-3 py-1.5 text-sm {outcome === option.value
          ? 'bg-primary text-primary-foreground'
          : 'text-muted-foreground hover:bg-muted'}"
        onclick={() => show(option.value)}>
        {option.label}
      </button>
    {/each}
  </div>

  <div class="overflow-x-auto">
    <table class="w-full text-left text-sm">
      <thead>
        <tr><th>Judged</th><th>Room</th><th>Verdict</th><th>Scores</th><th>Since</th></tr>
      </thead>
      <tbody>
        {#each sweeps as sweep (sweep.id)}
          <tr class="border-t align-top">
            <td class="py-3 whitespace-nowrap">{new Date(sweep.at).toLocaleString()}</td>
            <td>
              <a class="underline" href={sweep.chat.path}>{sweep.chat.title}</a>
              <p class="text-muted-foreground">{sweep.account} · quiet {sweep.quiet_minutes ?? '?'} min</p>
            </td>
            <td>
              {#if sweep.outcome === 'would_wake'}
                {sweep.woken.length ? `Woke ${sweep.woken.join(', ')}` : `Would wake ${sweep.would_wake.join(', ')}`}
                {#each sweep.held || [] as hold}
                  <p class="text-muted-foreground">{hold.name} held: {hold.reason.replaceAll('_', ' ')}</p>
                {/each}
                {#if sweep.stopped}<p class="text-muted-foreground">Automation stopped in this room</p>{/if}
              {:else if sweep.outcome === 'person_holds'}
                Waiting on a person
              {:else if sweep.outcome === 'error'}
                Error: {sweep.error_class}
              {:else}
                Nothing to do
              {/if}
            </td>
            <td class="whitespace-nowrap">
              {#each sweep.scores as score}
                <div>{score.name}: {percent(score.score)}</div>
              {/each}
              <div class="text-muted-foreground">person: {percent(sweep.person_holds)}</div>
            </td>
            <td>{sweep.moved_on ? 'Room has moved on' : 'Still quiet'}</td>
          </tr>
        {:else}
          <tr><td colspan="5" class="py-6 text-muted-foreground">No verdicts yet.</td></tr>
        {/each}
      </tbody>
    </table>
  </div>
  <p class="text-sm text-muted-foreground">Showing the newest 200.</p>
</div>
