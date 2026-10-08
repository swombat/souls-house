<script>
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Play } from 'phosphor-svelte';
  import SpeakerChip from '$lib/components/field/SpeakerChip.svelte';
  import SuggestionChip from '$lib/components/field/SuggestionChip.svelte';
  import { formatDuration } from '$lib/field-recordings';

  let { speaker, totalTalkMs = 0, onPlayClip, onSeek, ...chip } = $props();

  const share = $derived(totalTalkMs > 0 ? Math.round((100 * (speaker.talk_ms || 0)) / totalTalkMs) : null);
  const hasClip = $derived(speaker.clip_start_ms != null && speaker.clip_end_ms != null);
</script>

<Card.Root data-testid="speaker-card">
  <Card.Content class="p-3 space-y-2">
    <div>
      <p class="font-semibold truncate">{speaker.name || speaker.default_name}</p>
      <p class="text-xs text-muted-foreground">
        {formatDuration(speaker.talk_ms || 0)}{share != null ? ` · ${share}% of talk` : ''}
      </p>
    </div>
    <div class="flex flex-wrap items-center gap-1">
      {#if hasClip}
        <Button
          size="sm"
          variant="ghost"
          onclick={() => onPlayClip(speaker)}
          aria-label="Hear a few seconds of this voice">
          <Play class="size-4" weight="fill" /> Hear
        </Button>
      {/if}
      <SpeakerChip {speaker} {...chip} />
    </div>
    {#if speaker.suggestion && !speaker.named}
      <SuggestionChip suggestion={speaker.suggestion} url={chip.url} {onSeek} />
    {/if}
  </Card.Content>
</Card.Root>
