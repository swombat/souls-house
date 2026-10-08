<script>
  import { Link, page, router } from '@inertiajs/svelte';
  import { createDynamicSync } from '$lib/use-sync';
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import SpeakerCard from '$lib/components/field/SpeakerCard.svelte';
  import TranscriptTurns from '$lib/components/field/TranscriptTurns.svelte';
  import { formatWhen } from '$lib/field';
  import {
    activeWordIndex,
    buildTurns,
    formatDuration,
    recordingStatusLine,
    recordingsTabPath,
    speakerNames,
    timedWords,
  } from '$lib/field-recordings';
  import { ArrowClockwise, ArrowLeft, X } from 'phosphor-svelte';

  let {
    recording,
    speakers = [],
    voices = [],
    members_without_voice = [],
    my_voice_id = null,
    show_you_hint = false,
    suggestions_enabled = false,
    account,
  } = $props();

  const updateSync = createDynamicSync();
  $effect(() => {
    updateSync({ [`FieldRecording:${recording.id}`]: ['recording', 'speakers'] });
  });

  const ready = $derived(recording.status === 'ready');
  const troubled = $derived(recording.status === 'rejected' || recording.status === 'failed');
  const turns = $derived(buildTurns(recording.words));
  const wordList = $derived(timedWords(turns));
  const names = $derived(speakerNames(speakers));
  const totalTalkMs = $derived(speakers.reduce((sum, speaker) => sum + (speaker.talk_ms || 0), 0));
  const me = $derived($page.props?.user);
  const myName = $derived(me?.full_name || me?.first_name || '');
  const backPath = $derived(recordingsTabPath(account.id, recording.id));
  const meta = $derived(
    [
      recording.duration_ms != null ? formatDuration(recording.duration_ms) : null,
      recording.uploader_name ? `Brought by ${recording.uploader_name}` : null,
      formatWhen(recording.created_at),
    ]
      .filter(Boolean)
      .join(' · ')
  );

  let audio = $state(null);
  let currentMs = $state(null);
  // A "Hear" clip: play from start, pause at end. The seek the clip makes for
  // itself fires a `seeking` event too; only a seek that lands somewhere else
  // (the user dragging the player, or clicking a turn) ends the clip.
  let clip = null;
  const CLIP_SEEK_TOLERANCE_MS = 50;
  const activeIndex = $derived(activeWordIndex(wordList, currentMs));

  function timeUpdate() {
    if (!audio) return;
    currentMs = Math.round(audio.currentTime * 1000);
    if (clip && currentMs >= clip.endMs) {
      audio.pause();
      clip = null;
    }
  }

  function seeking() {
    if (!audio || !clip) return;
    if (Math.abs(audio.currentTime * 1000 - clip.startMs) <= CLIP_SEEK_TOLERANCE_MS) return;
    clip = null;
  }

  function seek(ms) {
    if (!audio) return;
    clip = null;
    audio.currentTime = ms / 1000;
    audio.play().catch(() => {});
  }

  function playClip(speaker) {
    if (!audio) return;
    clip = { startMs: speaker.clip_start_ms, endMs: speaker.clip_end_ms };
    audio.currentTime = speaker.clip_start_ms / 1000;
    audio.play().catch(() => {});
  }

  function retry() {
    router.post(`${recording.show_url}/retry`);
  }

  // The server answers 204, not an Inertia page, so this is a plain request.
  let hintDismissed = $state(false);
  function dismissHint() {
    hintDismissed = true;
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content');
    fetch(`/accounts/${account.id}/field/recordings/dismiss_you_hint`, {
      method: 'POST',
      headers: { 'X-CSRF-Token': csrfToken || '', Accept: 'application/json' },
    }).catch(() => {});
  }
</script>

<svelte:head>
  <title>{recording.title} · Field</title>
</svelte:head>

<div class="p-8 max-w-5xl mx-auto space-y-6">
  <div>
    <Link href={backPath} class="text-sm text-muted-foreground hover:text-foreground inline-flex items-center gap-1">
      <ArrowLeft class="size-4" /> Recordings
    </Link>
    <h1 class="text-3xl font-bold mt-2 break-words">{recording.title}</h1>
    <p class="text-muted-foreground mt-1">{meta}</p>
    {#if recording.note}
      <p class="mt-3 whitespace-pre-wrap">{recording.note}</p>
    {/if}
  </div>

  {#if recording.audio_url}
    <audio
      bind:this={audio}
      src={recording.audio_url}
      controls
      preload="metadata"
      class="w-full"
      ontimeupdate={timeUpdate}
      onseeking={seeking}
      data-testid="recording-audio"></audio>
  {/if}

  {#if !ready}
    <Card.Root>
      <Card.Content class="py-10 text-center space-y-3">
        <p class={troubled ? 'text-destructive' : 'text-muted-foreground'} data-testid="recording-status">
          {recordingStatusLine(recording)}
        </p>
        {#if !troubled}
          <p class="text-sm text-muted-foreground">
            You can leave this page. The transcript will be here when it's done.
          </p>
        {/if}
        {#if recording.retryable}
          <Button variant="outline" size="sm" onclick={retry}><ArrowClockwise class="size-4" /> Try again</Button>
        {/if}
      </Card.Content>
    </Card.Root>
  {:else}
    <section class="space-y-3">
      {#if show_you_hint && !hintDismissed}
        <div class="flex items-center gap-2 text-sm rounded-md bg-muted px-3 py-2" data-testid="you-hint">
          <p class="flex-1">Is one of these you? Tap <em>You</em> on their card.</p>
          <button class="text-muted-foreground hover:text-foreground" aria-label="Dismiss" onclick={dismissHint}>
            <X class="size-4" />
          </button>
        </div>
      {/if}
      {#if suggestions_enabled}
        <p class="text-xs text-muted-foreground" data-testid="suggestions-disclosure">
          Names may be suggested from what's said: the transcript, title and note are sent to Google Gemini (through
          OpenRouter) for that. A suggestion is only ever shown here, for a person to confirm or dismiss.
        </p>
      {/if}
      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {#each speakers as speaker (speaker.id)}
          <SpeakerCard
            {speaker}
            {totalTalkMs}
            onPlayClip={playClip}
            onSeek={seek}
            url={`/accounts/${account.id}/field/recordings/${recording.id}/speakers/${speaker.id}`}
            {voices}
            members={members_without_voice}
            myVoiceId={my_voice_id}
            myUserId={me?.id}
            {myName} />
        {/each}
      </div>
    </section>

    {#if turns.length}
      <Card.Root>
        <Card.Content class="p-6">
          <TranscriptTurns {turns} {names} {activeIndex} onSeek={seek} />
        </Card.Content>
      </Card.Root>
    {:else}
      <p class="text-muted-foreground">No words were heard in this recording.</p>
    {/if}
  {/if}
</div>
