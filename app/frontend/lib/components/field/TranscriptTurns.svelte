<script>
  import { formatClock, turnSpeakerName } from '$lib/field-recordings';

  // correcting: clicks pick words (or, for a supplied transcript, a turn) to
  // correct instead of seeking. selected: { from, to } source positions, or
  // { turn } for a supplied transcript.
  let { turns = [], names = {}, activeIndex = -1, onSeek, correcting = false, selected = null, onPick } = $props();

  function isSelected(part) {
    if (!selected || part.src == null) return false;
    if (selected.turn != null) return part.whole && part.src === selected.turn;
    return part.src >= selected.from && part.src <= selected.to;
  }

  function activate(part, t, event) {
    if (correcting) onPick?.(part, t, event?.shiftKey);
    else onSeek(part.s);
  }
</script>

<div class="space-y-4" data-testid="transcript">
  {#each turns as turn, t (t)}
    <div class="grid grid-cols-[4rem_1fr] gap-3">
      {#if turn.start != null}
        <button
          class="text-xs text-muted-foreground tabular-nums text-left pt-1 hover:text-foreground"
          onclick={() => onSeek(turn.start)}>
          {formatClock(turn.start)}
        </button>
      {:else}
        <span></span>
      {/if}
      <div>
        <p class="text-sm font-semibold {turn.spk ? '' : 'text-muted-foreground'}">{turnSpeakerName(turn, names)}</p>
        <p class="leading-relaxed">
          {#each turn.parts as part, p (p)}{#if part.k === 's'}{part.t}{:else if part.s == null && !correcting}<span
                class="whitespace-pre-line">{part.t}</span
              >{:else}<span
                role="button"
                tabindex="-1"
                data-testid="transcript-word"
                title={part.c ? 'Corrected; its timing spans the words it replaced' : undefined}
                class="cursor-pointer rounded hover:bg-muted {part.whole ? 'whitespace-pre-line' : ''} {part.k === 'a'
                  ? 'italic text-muted-foreground'
                  : ''} {part.c ? 'underline decoration-dotted underline-offset-4' : ''} {part.i === activeIndex
                  ? 'bg-primary/20'
                  : ''} {isSelected(part) ? 'bg-amber-200 dark:bg-amber-800' : ''}"
                onclick={(e) => activate(part, t, e)}
                onkeydown={(e) => e.key === 'Enter' && activate(part, t, e)}>{part.t}</span
              >{/if}{/each}
        </p>
      </div>
    </div>
  {/each}
</div>
