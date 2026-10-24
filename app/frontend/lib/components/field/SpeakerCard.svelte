<script>
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import * as DropdownMenu from '$lib/components/shadcn/dropdown-menu/index.js';
  import { Play, CaretDown } from 'phosphor-svelte';
  import SpeakerChip from '$lib/components/field/SpeakerChip.svelte';
  import SuggestionChip from '$lib/components/field/SuggestionChip.svelte';
  import RecognitionChip from '$lib/components/field/RecognitionChip.svelte';
  import { formatDuration, automaticParts } from '$lib/field-recordings';

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
  // Diarized speakers a person linked to this one voice. Each can still be
  // heard alone and unlinked: the transcriber may have merged two people too.
  const merged = $derived(parts.length > 1);
  let showParts = $state(false);
  let unlinking = $state(null);
  const partHasClip = (part) => part.clip_start_ms != null && part.clip_end_ms != null;

  function unlink(part) {
    unlinking = part.id;
    router.patch(
      speakerUrl(part),
      { speaker: { unname: true } },
      { preserveScroll: true, preserveState: true, onFinish: () => (unlinking = null) }
    );
  }

  // Dismiss: stop asking for a name, either as noise (not a person) or as
  // someone who stays anonymous (a person whose identity doesn't matter
  // here). Undo asks again.
  let settingAside = $state(false);
  const anonymous = $derived(speaker.ignored && speaker.ignored_as === 'anonymous');
  function setIgnored(ignoredAs) {
    settingAside = true;
    router.patch(
      chip.url,
      { speaker: ignoredAs ? { ignore: true, ignore_as: ignoredAs } : { unignore: true } },
      { preserveScroll: true, preserveState: true, onFinish: () => (settingAside = false) }
    );
  }

  // The parts of this card the house named by voice, whichever part stands
  // for the card: a merged card can mix a person's naming with an automatic
  // one, and the automatic provenance still shows. "Not them" un-names only
  // those parts, which counts as a person's decision, so nothing guesses at
  // them again; a part a person named stays named.
  const automatic = $derived(automaticParts(parts.length ? parts : [speaker]));
  const autoNamed = $derived(automatic.find((part) => part.id === speaker.id) || automatic[0]);
  const provenance = $derived.by(() => {
    if (!autoNamed) return '';
    const label = automatic.length < parts.length ? 'Partly named by voice' : 'Named by voice';
    const score = autoNamed.auto_named?.confidence;
    return score != null ? `${label} · match ${score}` : label;
  });
  let unnaming = $state(false);
  function notThem() {
    if (!automatic.length) return;
    unnaming = true;
    const [first, ...rest] = automatic;
    const companions = rest.map((part) => part.id);
    router.patch(
      speakerUrl ? speakerUrl(first) : chip.url,
      { speaker: companions.length ? { unname: true, with: companions } : { unname: true } },
      { preserveScroll: true, preserveState: true, onFinish: () => (unnaming = false) }
    );
  }
</script>

<Card.Root
  data-testid="speaker-card"
  data-ignored={speaker.ignored ? (speaker.ignored_as || 'noise') : null}
  class={speaker.ignored && !anonymous ? 'opacity-60' : ''}>
  <Card.Content class="p-3 space-y-2">
    <div>
      <p class="font-semibold truncate">{speaker.name || speaker.default_name}</p>
      {#if speaker.named && autoNamed}
        <p class="text-xs text-muted-foreground" data-testid="speaker-auto-named">
          {provenance}
          ·
          <button
            class="underline-offset-2 hover:underline hover:text-foreground disabled:opacity-50"
            disabled={unnaming}
            onclick={notThem}
            data-testid="speaker-auto-unname">Not {speaker.name}</button>
        </p>
      {/if}
      {#if speaker.ignored && !anonymous}
        <p class="text-xs text-muted-foreground">Dismissed as noise</p>
      {:else if speaker.talk_ms != null || anonymous}
        <p class="text-xs text-muted-foreground">
          {#if anonymous}Staying anonymous{speaker.talk_ms != null ? ' · ' : ''}{/if}{#if speaker.talk_ms != null}{formatDuration(
              speaker.talk_ms || 0
            )}{share != null ? ` · ${share}% of talk` : ''}{/if}
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
          onclick={() => setIgnored(null)}
          data-testid="speaker-unignore">
          Undo
        </Button>
        <Button
          size="sm"
          variant="ghost"
          class="text-muted-foreground"
          disabled={settingAside}
          onclick={() => setIgnored(anonymous ? 'noise' : 'anonymous')}
          data-testid="speaker-switch-dismissal">
          {anonymous ? 'Noise instead' : 'Stay anonymous instead'}
        </Button>
      {:else}
        <SpeakerChip {speaker} {...chip} />
        {#if !speaker.named && !merged}
          <DropdownMenu.Root>
            <DropdownMenu.Trigger
              disabled={settingAside}
              data-testid="speaker-dismiss"
              class="inline-flex items-center gap-1 h-8 px-3 rounded-md text-sm font-medium text-muted-foreground hover:bg-accent hover:text-accent-foreground disabled:opacity-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
              Dismiss <CaretDown class="size-3" />
            </DropdownMenu.Trigger>
            <DropdownMenu.Content align="start" class="w-64">
              <DropdownMenu.Item onclick={() => setIgnored('noise')} data-testid="speaker-ignore">
                <div>
                  <p class="text-sm">Dismiss as noise</p>
                  <p class="text-xs text-muted-foreground">Not a person: a cough, the room, a mishearing</p>
                </div>
              </DropdownMenu.Item>
              <DropdownMenu.Item onclick={() => setIgnored('anonymous')} data-testid="speaker-anonymous">
                <div>
                  <p class="text-sm">Stay anonymous</p>
                  <p class="text-xs text-muted-foreground">A real person, but who they are doesn't matter here</p>
                </div>
              </DropdownMenu.Item>
            </DropdownMenu.Content>
          </DropdownMenu.Root>
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
    {#if recognitionEnabled && speaker.recognition && !speaker.named}
      <RecognitionChip recognition={speaker.recognition} url={chip.url} />
    {/if}
  </Card.Content>
</Card.Root>
