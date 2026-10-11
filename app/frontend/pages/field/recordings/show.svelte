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
    suppliedTurns,
    timedWords,
  } from '$lib/field-recordings';
  import { ArrowClockwise, ArrowCounterClockwise, ArrowLeft, PencilSimple, X } from 'phosphor-svelte';

  let {
    recording,
    speakers = [],
    voices = [],
    members_without_voice = [],
    my_voice_id = null,
    show_you_hint = false,
    suggestions_enabled = false,
    recognition_enabled = false,
    account,
  } = $props();

  const updateSync = createDynamicSync();
  $effect(() => {
    updateSync({ [`FieldRecording:${recording.id}`]: ['recording', 'speakers'] });
  });

  const ready = $derived(recording.status === 'ready');
  const troubled = $derived(recording.status === 'rejected' || recording.status === 'failed');
  // Supplied transcripts (brought in with the audio) have turns, not timed
  // words: no word highlighting, talk time, clips or voice samples.
  const supplied = $derived(recording.transcript_source === 'supplied');
  const turns = $derived(supplied ? suppliedTurns(recording.turns) : buildTurns(recording.words));
  const wordList = $derived(supplied ? [] : timedWords(turns));
  const names = $derived(speakerNames(speakers));
  const totalTalkMs = $derived(speakers.reduce((sum, speaker) => sum + (speaker.talk_ms || 0), 0));
  const me = $derived($page.props?.user);
  const myName = $derived(me?.full_name || me?.first_name || '');
  const backPath = $derived(recordingsTabPath(account.id, recording.id));
  const meta = $derived(
    [
      recording.duration_ms != null ? formatDuration(recording.duration_ms) : null,
      recording.recorded_at ? `Recorded ${formatWhen(recording.recorded_at)}` : null,
      supplied ? 'Transcript brought with it' : null,
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
    if (!audio || ms == null) return;
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

  // Correcting the transcript. Scribe transcripts: click a word, shift-click
  // to extend the run within its turn; the run's positions are into the
  // stored words, spacing included. Supplied transcripts: click a turn.
  let correcting = $state(false);
  let selected = $state(null);
  let draft = $state('');
  let savingCorrection = $state(false);
  const corrections = $derived(recording.transcript_corrections || []);

  function toggleCorrecting() {
    correcting = !correcting;
    selected = null;
  }

  function pick(part, turnIndex, extend) {
    if (supplied) {
      selected = { turn: part.src };
      draft = part.t;
      return;
    }
    if (extend && selected && selected.turnIndex === turnIndex) {
      selected = {
        from: Math.min(selected.from, part.src),
        to: Math.max(selected.to, part.src),
        turnIndex,
      };
    } else {
      selected = { from: part.src, to: part.src, turnIndex };
    }
    draft = (recording.words || [])
      .slice(selected.from, selected.to + 1)
      .map((word) => word.t)
      .join('')
      .trim();
  }

  function saveCorrection(event) {
    event.preventDefault();
    if (!selected) return;
    const correction = supplied
      ? { turn: selected.turn, text: draft }
      : { from: selected.from, to: selected.to, text: draft };
    savingCorrection = true;
    router.patch(
      `${recording.show_url}/transcript`,
      { revision: recording.transcript_revision, corrections: [correction] },
      {
        preserveScroll: true,
        preserveState: true,
        onSuccess: () => (selected = null),
        onFinish: () => (savingCorrection = false),
      }
    );
  }

  function undoCorrection() {
    router.post(
      `${recording.show_url}/transcript/undo`,
      { revision: recording.transcript_revision },
      { preserveScroll: true, preserveState: true }
    );
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
    {#if recording.source_path}
      <p class="mt-1 text-xs text-muted-foreground break-all" data-testid="recording-source">
        From {recording.source_path}
      </p>
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
      {#if suggestions_enabled && !supplied}
        <p class="text-xs text-muted-foreground" data-testid="suggestions-disclosure">
          Names may be suggested from what's said: the transcript, title and note, with the names of this Field's voices
          and members, are sent to Google Gemini (through OpenRouter) for that. A suggestion is only ever shown here,
          for a person to confirm or dismiss.
        </p>
      {/if}
      <div class="flex justify-end">
        <Link
          href={`/accounts/${account.id}/field/voices`}
          class="text-sm text-muted-foreground hover:text-foreground underline-offset-2 hover:underline"
          >Voices this Field knows</Link>
      </div>
      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {#each speakers as speaker (speaker.id)}
          <SpeakerCard
            {speaker}
            {totalTalkMs}
            onPlayClip={playClip}
            onSeek={seek}
            recognitionEnabled={recognition_enabled && !supplied}
            accountId={account.id}
            recordingId={recording.id}
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
      <div class="flex flex-wrap items-center gap-2">
        <Button
          size="sm"
          variant={correcting ? 'default' : 'outline'}
          onclick={toggleCorrecting}
          data-testid="correct-transcript-toggle">
          <PencilSimple class="size-4" />
          {correcting ? 'Done correcting' : 'Correct the transcript'}
        </Button>
        {#if correcting && !selected}
          <p class="text-sm text-muted-foreground">
            {supplied
              ? 'Click the turn to correct.'
              : 'Click the word to correct; shift-click another in the same turn to take the words between.'}
          </p>
        {/if}
      </div>
      {#if correcting && selected}
        <form
          onsubmit={saveCorrection}
          class="sticky top-2 z-10 flex flex-wrap items-start gap-2 rounded-md border bg-background p-3 shadow-sm"
          data-testid="transcript-correction-form">
          <label for="transcript-correction" class="sr-only">Corrected words</label>
          {#if supplied}
            <textarea
              id="transcript-correction"
              bind:value={draft}
              rows="4"
              class="flex-1 min-w-64 rounded-md border border-input bg-background px-3 py-2 text-sm"></textarea>
          {:else}
            <input
              id="transcript-correction"
              bind:value={draft}
              maxlength="500"
              class="flex-1 min-w-64 rounded-md border border-input bg-background px-3 py-1.5 text-sm" />
          {/if}
          <Button type="submit" size="sm" disabled={savingCorrection}>Save correction</Button>
          <Button type="button" size="sm" variant="ghost" onclick={() => (selected = null)}>Cancel</Button>
          {#if !supplied}
            <p class="basis-full text-xs text-muted-foreground">
              Leave it empty to remove these words. A corrected run keeps the timing of the words it replaces.
            </p>
          {/if}
        </form>
      {/if}
      <Card.Root>
        <Card.Content class="p-6">
          <TranscriptTurns {turns} {names} {activeIndex} onSeek={seek} {correcting} {selected} onPick={pick} />
        </Card.Content>
      </Card.Root>
      {#if corrections.length}
        <section class="space-y-2" data-testid="transcript-corrections">
          <div class="flex items-center justify-between gap-2">
            <h2 class="text-sm uppercase tracking-wide text-muted-foreground">Corrections</h2>
            {#if recording.undoable_correction_id}
              <Button size="sm" variant="ghost" onclick={undoCorrection} data-testid="undo-transcript-correction">
                <ArrowCounterClockwise class="size-4" /> Undo the last correction
              </Button>
            {/if}
          </div>
          <ul class="text-sm space-y-1">
            {#each corrections as correction (correction.id)}
              <li class={correction.undone ? 'text-muted-foreground line-through' : ''}>
                {correction.kind === 'undo' ? 'Undid a correction' : correction.changes.join('; ')}
                {#if correction.change_count > correction.changes.length}
                  (and {correction.change_count - correction.changes.length} more)
                {/if}
                <span class="text-muted-foreground">
                  · {correction.by || 'someone'} · {formatWhen(correction.at)}
                </span>
              </li>
            {/each}
          </ul>
        </section>
      {/if}
    {:else}
      <p class="text-muted-foreground">No words were heard in this recording.</p>
    {/if}
  {/if}
</div>
