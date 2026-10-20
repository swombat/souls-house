<script>
  import { Link, page, router } from '@inertiajs/svelte';
  import { createDynamicSync } from '$lib/use-sync';
  import { reloadProps } from '$lib/cable';
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import SpeakerCard from '$lib/components/field/SpeakerCard.svelte';
  import RecordingNotes from '$lib/components/field/RecordingNotes.svelte';
  import TranscriptTurns from '$lib/components/field/TranscriptTurns.svelte';
  import { formatWhen } from '$lib/field';
  import {
    activeWordIndex,
    buildTurns,
    formatDuration,
    groupSpeakers,
    recordingStatusLine,
    recordingsTabPath,
    speakerKeys,
    speakerNames,
    suppliedTurns,
    timedWords,
  } from '$lib/field-recordings';
  import { ArrowClockwise, ArrowLeft, Trash, X } from 'phosphor-svelte';

  let {
    recording,
    words = [],
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
    updateSync({
      [`FieldRecording:${recording.id}`]: ['recording', 'speakers'],
      [`FieldVoiceActivity:${account.id}`]: ['voices', 'members_without_voice', 'my_voice_id', 'recognition_enabled'],
    });
  });

  // The transcript's words are a separate prop, so the refreshes above never
  // resend them (a long meeting is tens of thousands of words). They are asked
  // for only when the recording says its transcript changed: it finished
  // transcribing, or someone corrected a line. A full visit brings both at
  // once, which counts as already loaded.
  let wordsSeen = words;
  let wordsRevision = recording.transcript_revision;
  $effect(() => {
    const revision = recording.transcript_revision;
    if (words !== wordsSeen) {
      wordsSeen = words;
      wordsRevision = revision;
    } else if (revision !== wordsRevision) {
      wordsRevision = revision;
      reloadProps(['words']);
    }
  });

  const ready = $derived(recording.status === 'ready');
  const troubled = $derived(recording.status === 'rejected' || recording.status === 'failed');
  // Supplied transcripts (brought in with the audio) have turns, not timed
  // words: no word highlighting, talk time, clips or voice samples.
  const supplied = $derived(recording.transcript_source === 'supplied');
  const turns = $derived(supplied ? suppliedTurns(recording.turns) : buildTurns(words, speakerKeys(speakers)));
  // One card per person: diarized speakers linked to one voice share a card.
  const groups = $derived(groupSpeakers(speakers));
  const speakerUrl = (speaker) => `/accounts/${account.id}/field/recordings/${recording.id}/speakers/${speaker.id}`;
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

  // One line corrected by hand. Resolves {ok} only when the server took it;
  // a refusal (the transcript changed meanwhile, an empty line) or a failed
  // request resolves {ok: false} with why, and the editor keeps the text.
  function saveLine(edit, text) {
    return new Promise((resolve) => {
      let settled = false;
      const settle = (result) => {
        if (settled) return;
        settled = true;
        resolve(result);
      };
      router.patch(
        `${recording.show_url}/line`,
        { line: { ...edit.address, text, was: edit.was, revision: edit.revision } },
        {
          preserveScroll: true,
          preserveState: true,
          onSuccess: () => settle({ ok: true }),
          onError: (errors) => settle({ ok: false, error: errors?.line }),
          onFinish: () => settle({ ok: false }),
        }
      );
    });
  }

  // One line given to another speaker (or "new"). Resolves like saveLine.
  function reassignLine(edit, speakerId) {
    return new Promise((resolve) => {
      let settled = false;
      const settle = (result) => {
        if (settled) return;
        settled = true;
        resolve(result);
      };
      router.patch(
        `${recording.show_url}/line_speaker`,
        { line: { ...edit.address, was: edit.was, revision: edit.revision, speaker: speakerId } },
        {
          preserveScroll: true,
          preserveState: true,
          onSuccess: () => settle({ ok: true }),
          onError: (errors) => settle({ ok: false, error: errors?.line_speaker }),
          onFinish: () => settle({ ok: false }),
        }
      );
    });
  }

  // Who a line can be given to: one entry per person, as the cards show them.
  const speakerChoices = $derived(
    groups.map((group) => ({
      id: group.speaker.id,
      name: group.speaker.name || group.speaker.default_name || group.speaker.label,
      labels: group.parts.map((part) => part.label),
    }))
  );

  function retry() {
    router.post(`${recording.show_url}/retry`);
  }

  // The passes that ran when the transcript landed, run again: voices this
  // Field has remembered since, and names it has learned. Only speakers nobody
  // has decided about get a guess, and a guess waits for a person to confirm.
  let lookingAgain = $state(false);
  function identifyAgain() {
    lookingAgain = true;
    router.post(
      `${recording.show_url}/identify_again`,
      {},
      {
        preserveScroll: true,
        onFinish: () => (lookingAgain = false),
      }
    );
  }

  // The same discard as the Field list's Delete: the recording leaves the
  // index, search and residents' reads; the server sends us back to the list.
  function remove() {
    const message =
      `Delete "${recording.title}" from the Field? It disappears for everyone, people and residents. ` +
      'Deleting does not reach anything a resident has already read: quotes in chats and things kept in ' +
      'memory stay where they are.' +
      (recording.dispatched ? " It has started transcribing, so deleting it doesn't give its minutes back." : '');
    if (!confirm(message)) return;
    router.delete(recording.show_url);
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
    <div class="flex items-start justify-between gap-3 mt-2">
      <h1 class="text-3xl font-bold break-words min-w-0">{recording.title}</h1>
      <Button
        variant="ghost"
        size="sm"
        class="shrink-0 text-muted-foreground hover:text-destructive"
        onclick={remove}
        title="Delete recording"
        aria-label="Delete recording"
        data-testid="delete-recording">
        <Trash class="size-4" /> Delete
      </Button>
    </div>
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

  <RecordingNotes {recording} />

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
      <div class="flex items-center justify-end gap-3">
        {#if (recognition_enabled || suggestions_enabled) && !supplied}
          <Button
            variant="ghost"
            size="sm"
            class="text-muted-foreground"
            onclick={identifyAgain}
            disabled={lookingAgain}
            title="Look for voices and names this Field has learned since this transcript was made"
            data-testid="identify-again">
            <ArrowClockwise class="size-4" /> Look for known voices again
          </Button>
        {/if}
        <Link
          href={`/accounts/${account.id}/field/voices`}
          class="text-sm text-muted-foreground hover:text-foreground underline-offset-2 hover:underline"
          >Voices this Field knows</Link>
      </div>
      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {#each groups as group (group.key)}
          <SpeakerCard
            speaker={group.speaker}
            parts={group.parts}
            {speakerUrl}
            {totalTalkMs}
            onPlayClip={playClip}
            onSeek={seek}
            recognitionEnabled={recognition_enabled && !supplied}
            accountId={account.id}
            recordingId={recording.id}
            url={speakerUrl(group.speaker)}
            with={group.parts.filter((part) => part.id !== group.speaker.id).map((part) => part.id)}
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
          <TranscriptTurns
            {turns}
            {names}
            {activeIndex}
            onSeek={seek}
            onSave={saveLine}
            onReassign={reassignLine}
            choices={speakerChoices}
            revision={recording.transcript_revision} />
        </Card.Content>
      </Card.Root>
    {:else}
      <p class="text-muted-foreground">No words were heard in this recording.</p>
    {/if}
  {/if}
</div>
