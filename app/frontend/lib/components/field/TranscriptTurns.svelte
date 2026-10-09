<script>
  import { formatClock, turnSpeakerName } from '$lib/field-recordings';

  let { turns = [], names = {}, activeIndex = -1, onSeek } = $props();
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
          {#each turn.parts as part, p (p)}{#if part.k === 's'}{part.t}{:else if part.s == null}<span
                class="whitespace-pre-line">{part.t}</span
              >{:else}<span
                role="button"
                tabindex="-1"
                class="cursor-pointer rounded hover:bg-muted {part.whole ? 'whitespace-pre-line' : ''} {part.k === 'a'
                  ? 'italic text-muted-foreground'
                  : ''} {part.i === activeIndex ? 'bg-primary/20' : ''}"
                onclick={() => onSeek(part.s)}
                onkeydown={(e) => e.key === 'Enter' && onSeek(part.s)}>{part.t}</span
              >{/if}{/each}
        </p>
      </div>
    </div>
  {/each}
</div>
