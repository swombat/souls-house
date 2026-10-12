<script>
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Play } from 'phosphor-svelte';
  import SpeakerChip from '$lib/components/field/SpeakerChip.svelte';
  import SuggestionChip from '$lib/components/field/SuggestionChip.svelte';
  import RecognitionChip from '$lib/components/field/RecognitionChip.svelte';
  import RememberVoice from '$lib/components/field/RememberVoice.svelte';
  import { formatDuration, partsWithOwnEnrolment } from '$lib/field-recordings';

  let {
    speaker,
    parts = [],
    speakerUrl = null,
    totalTalkMs = 0,
    onPlayClip,
    onSeek,
    recognitionEnabled = false,
    accountId = null,
    recordingId = null,
    ...chip
  } = $props();

  const share = $derived(totalTalkMs > 0 ? Math.round((100 * (speaker.talk_ms || 0)) / totalTalkMs) : null);
  const hasClip = $derived(speaker.clip_start_ms != null && speaker.clip_end_ms != null);
  const isMe = $derived(!!chip.myVoiceId && speaker.voice_id === chip.myVoiceId);
  // Diarized speakers a person linked to this one voice. Each can still be
  // heard alone and unlinked: the transcriber may have merged two people too.
  const merged = $derived(parts.length > 1);
  let showParts = $state(false);
  let unlinking = $state(null);
  const partHasClip = (part) => part.clip_start_ms != null && part.clip_end_ms != null;
  // A sample preview or a remembering in progress belongs to the diarized
  // speaker it was taken from, not to the card's representative: keep each
  // one on view, with its own Use it / Not them.
  const ownEnrolments = $derived(partsWithOwnEnrolment(parts, speaker));

  function unlink(part) {
    unlinking = part.id;
    router.patch(
      speakerUrl(part),
      { speaker: { unname: true } },
      { preserveScroll: true, preserveState: true, onFinish: () => (unlinking = null) }
    );
  }

  // Noise rather than a person: stop asking for a name (and undo that).
  let settingAside = $state(false);
  function setIgnored(ignored) {
    settingAside = true;
    router.patch(
      chip.url,
      { speaker: ignored ? { ignore: true } : { unignore: true } },
      { preserveScroll: true, preserveState: true, onFinish: () => (settingAside = false) }
    );
  }
</script>

<Card.Root data-testid="speaker-card" data-ignored={speaker.ignored ? 'true' : null} class={speaker.ignored ? 'opacity-60' : ''}>
  <Card.Content class="p-3 space-y-2">
    <div>
      <p class="font-semibold truncate">{speaker.name || speaker.default_name}</p>
      {#if speaker.ignored}
        <p class="text-xs text-muted-foreground">Ignored as noise</p>
      {:else if speaker.talk_ms != null}
        <p class="text-xs text-muted-foreground">
          {formatDuration(speaker.talk_ms || 0)}{share != null ? ` · ${share}% of talk` : ''}
        </p>
      {/if}
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
      {#if speaker.ignored}
        <Button
          size="sm"
          variant="ghost"
          disabled={settingAside}
          onclick={() => setIgnored(false)}
          data-testid="speaker-unignore">
          Undo
        </Button>
      {:else}
        <SpeakerChip {speaker} {...chip} />
        {#if !speaker.named && !merged}
          <Button
            size="sm"
            variant="ghost"
            class="text-muted-foreground"
            disabled={settingAside}
            onclick={() => setIgnored(true)}
            title="Noise, not a person: stop asking for a name"
            data-testid="speaker-ignore">
            Just noise
          </Button>
        {/if}
      {/if}
    </div>
    {#if merged}
      <button
        class="text-xs text-muted-foreground hover:text-foreground underline-offset-2 hover:underline"
        onclick={() => (showParts = !showParts)}
        aria-expanded={showParts}
        data-testid="speaker-parts-toggle">
        Heard as {parts.length} speakers
      </button>
      {#if showParts}
        <ul class="space-y-1" data-testid="speaker-parts">
          {#each parts as part (part.id)}
            <li class="flex items-center gap-1 text-xs">
              <span class="flex-1 text-muted-foreground truncate">
                {part.default_name}{part.talk_ms != null ? ` · ${formatDuration(part.talk_ms)}` : ''}
              </span>
              {#if partHasClip(part)}
                <Button
                  size="sm"
                  variant="ghost"
                  class="h-7 px-2"
                  onclick={() => onPlayClip(part)}
                  aria-label={`Hear ${part.default_name}`}>
                  <Play class="size-3" weight="fill" /> Hear
                </Button>
              {/if}
              <Button
                size="sm"
                variant="ghost"
                class="h-7 px-2"
                disabled={unlinking != null}
                onclick={() => unlink(part)}
                data-testid="speaker-part-unlink">
                Not {speaker.name}
              </Button>
            </li>
          {/each}
        </ul>
      {/if}
    {/if}
    {#if speaker.suggestion && !speaker.named}
      <SuggestionChip suggestion={speaker.suggestion} url={chip.url} {onSeek} />
    {/if}
    {#if recognitionEnabled}
      {#if speaker.recognition && !speaker.named}
        <RecognitionChip recognition={speaker.recognition} url={chip.url} />
      {/if}
      {#if speaker.named}
        <RememberVoice {speaker} {accountId} {recordingId} {isMe} />
        {#each ownEnrolments as part (part.id)}
          <div class="space-y-1" data-testid="speaker-part-enrolment">
            <p class="text-xs text-muted-foreground">From {part.default_name}</p>
            <RememberVoice speaker={part} {accountId} {recordingId} {isMe} offer={false} />
          </div>
        {/each}
      {/if}
    {/if}
  </Card.Content>
</Card.Root>
