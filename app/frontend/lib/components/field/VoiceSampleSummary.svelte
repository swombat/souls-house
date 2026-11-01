<script>
  // Above a voice's sample list: the print's state, the counts, and what to do.
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { STATES } from './voice-sample-format.js';

  let { result, counts, name, busy = false, onPrepare } = $props();
</script>

<div class="flex flex-wrap items-center justify-between gap-2">
  <div class="text-sm">
    <p data-testid="voice-print-state">{result.print}</p>
    {#if result.learning !== 'Learning enabled'}<p class="text-muted-foreground">{result.learning}</p>{/if}
  </div>
  {#if result.preparable > 0}
    <Button size="sm" disabled={busy} onclick={onPrepare} data-testid="voice-prepare">
      Prepare {result.preparable}
      {result.preparable === 1 ? 'sample' : 'samples'} for listening
    </Button>
  {/if}
</div>

{#if result.samples.length === 0}
  <p class="text-sm text-muted-foreground">No fingerprint samples yet.</p>
{:else}
  <p class="text-xs text-muted-foreground">
    {result.total}
    {result.total === 1 ? 'sample' : 'samples'}
    {#each Object.keys(STATES) as state (state)}
      {#if counts[state]}<span> · {counts[state]} {STATES[state].label.toLowerCase()}</span>{/if}
    {/each}.
    {#if result.full}
      Twenty samples are included, which is as many as a fingerprint uses, so no new ones are offered. Reject one if it
      is wrong, and candidates are offered again.
    {:else}
      Accept after playing a sample to the end, if it is only {name} throughout. Wrong person or mixed voices: reject it,
      then correct the speaker in the recording.
    {/if}
  </p>
{/if}
