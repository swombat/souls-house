<script>
  // Turns that were heard and not sent (voice-mode-held.js). The front one
  // says why and can be retried; the ones behind it wait so the conversation
  // stays in the order things were said. Any of them can be discarded.
  let { held = [], onretry, ondiscard } = $props();

  const seconds = (ms) => Math.max(1, Math.round((ms || 0) / 1000));
</script>

{#if held.length}
  <div class="space-y-2" data-testid="voice-mode-held">
    {#each held as turn, index (turn.id)}
      <div
        class="rounded-md border border-amber-300 dark:border-amber-700 p-2 text-sm space-y-1"
        data-testid="voice-mode-held-turn"
        data-state={turn.state}>
        <p class={turn.transcribed ? '' : 'italic text-muted-foreground'}>
          {turn.transcribed ? turn.text : `${seconds(turn.durationMs)}s of speech, not transcribed yet`}
        </p>
        <p class="text-xs text-amber-700 dark:text-amber-400" data-testid="voice-mode-held-reason">
          {#if turn.state === 'retrying'}
            Sending again…
          {:else if turn.state === 'waiting'}
            Not sent yet: waiting behind the turn above.
          {:else}
            Not sent: {turn.error}
          {/if}
        </p>
        <div class="flex gap-2">
          {#if index === 0 && turn.state === 'failed'}
            <button
              type="button"
              class="text-xs px-2 py-1 rounded-md bg-primary text-primary-foreground hover:bg-primary/90"
              onclick={() => onretry?.()}>
              Retry
            </button>
          {/if}
          {#if turn.state !== 'retrying'}
            <button
              type="button"
              class="text-xs px-2 py-1 rounded-md hover:bg-accent"
              onclick={() => ondiscard?.(turn.id)}>
              Discard
            </button>
          {/if}
        </div>
      </div>
    {/each}
  </div>
{/if}
