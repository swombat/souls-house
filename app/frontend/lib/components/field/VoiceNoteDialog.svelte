<script>
  // Record now: speak straight into the Field. Opening the dialog starts the
  // microphone (the browser asks first if it needs to). Stop ends the take and
  // shows it for listening; Save to Field sends it through the same upload and
  // transcription as a recording brought in from a file. While there is a live
  // or unsaved take the dialog can only be left by Save or Discard: Escape, a
  // tap outside and the X are off, so a stray tap can't lose the thought. The
  // take's lifecycle (and why only `stop` ends it) is in voice-note-take.js.
  import { onDestroy, untrack } from 'svelte';
  import { router } from '@inertiajs/svelte';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import VoiceNoteReview from '$lib/components/field/VoiceNoteReview.svelte';
  import { directUpload } from '$lib/field-direct-upload';
  import { holdForRecording } from '$lib/recording-guard';
  import { createTake } from '$lib/voice-note-take.js';
  import { formatElapsed, voiceNoteFile, voiceNoteTitle } from '$lib/mic-recorder.js';

  let { open = $bindable(false), accountId, sharedLine = '' } = $props();

  // idle → starting → recording → review ⇄ saving; failed when the mic can't start.
  let phase = $state('idle');
  let elapsed = $state(0);
  let title = $state('');
  let error = $state('');
  let progress = $state(null);
  let take = $state(null); // { file, url, startedAt, durationMs }
  let ended = $state('');
  // The upload made for this take, kept so a retry re-sends the same blob: the
  // server refuses a blob already attached, so a retry can't make a second one.
  let uploaded = null;
  let unconfirmed = $state(false);

  let current = null; // the live take
  let startedAt = null;
  let ticker = null;
  let attempt = null;
  let releaseHold = null;
  // The POST in flight; unmount drops it so a late answer can't hold the page.
  let posting = null;
  const CANCELLED = Symbol('cancelled');

  const holding = $derived(phase !== 'idle' && phase !== 'failed');

  $effect(() => {
    if (open) untrack(() => phase === 'idle' && start());
    else untrack(() => discard());
  });

  // Leaving the page (a confirmed visit) unmounts the dialog without closing it.
  onDestroy(() => discard({ force: true }));

  function hold(warn = true) {
    const next = holdForRecording(warn ? {} : { warn: false });
    releaseHold?.();
    releaseHold = next;
  }

  function letGo() {
    releaseHold?.();
    releaseHold = null;
  }

  function start() {
    reset();
    phase = 'starting';
    const mine = createTake({
      onLive: (at) => {
        if (current !== mine) return;
        startedAt = at;
        title = voiceNoteTitle(at);
        hold();
        phase = 'recording';
        ticker = setInterval(() => {
          if (mine.recording) elapsed = Date.now() - at.getTime();
          else mine.lost();
        }, 250);
      },
      onEnded: ({ chunks, mimeType, reason }) => {
        if (current !== mine) return;
        clearInterval(ticker);
        current = null;
        elapsed = Date.now() - startedAt.getTime();
        ended = reason;
        if (!chunks.length) return fail('Nothing was recorded. Please try again.');
        const file = voiceNoteFile(chunks, mimeType, title);
        take = { file, url: URL.createObjectURL(file), startedAt, durationMs: elapsed };
        phase = 'review';
      },
      onFailed: (message) => current === mine && fail(message),
    });
    current = mine;
    mine.start();
  }

  function fail(message) {
    clearInterval(ticker);
    current?.dispose();
    current = null;
    letGo();
    error = message;
    phase = 'failed';
  }

  function stop() {
    if (phase !== 'recording' || !current) return;
    clearInterval(ticker);
    current.stop();
  }

  async function save(event) {
    event?.preventDefault();
    if (!take || phase !== 'review') return;
    const name = title.trim() || voiceNoteTitle(take.startedAt);
    phase = 'saving';
    error = '';
    if (!uploaded) {
      const mine = { cancelled: false, posting: false, xhrs: [], createXhr: null, fail: () => {} };
      attempt = mine;
      progress = 0;
      try {
        const file = voiceNoteFile([take.file], take.file.type, name);
        const blob = await directUpload(file, `/accounts/${accountId}/field/recordings/uploads`, mine, (fraction) => {
          if (attempt === mine) progress = fraction;
        });
        if (mine.cancelled || attempt !== mine) return;
        uploaded = { signedId: blob.signed_id };
      } catch (failure) {
        if (failure === CANCELLED || mine.cancelled) return;
        attempt = null;
        error = typeof failure === 'string' ? failure : 'The upload stopped. Your voice note is still here; try again.';
        phase = 'review';
        progress = null;
        return;
      }
      attempt = null;
    }
    post(name);
  }

  function post(name) {
    const retrying = unconfirmed;
    let answered = false;
    const mine = Symbol('post');
    posting = mine;
    progress = 1;
    // Our own save is not leaving the page: trade the hold that asks
    // "discard the recording?" for a quiet one until the save is answered.
    hold(false);
    router.post(
      `/accounts/${accountId}/field/recordings`,
      {
        field_recording: {
          upload_id: uploaded.signedId,
          title: name,
          note: '',
          expected_speakers: 1,
          recorded_at: take.startedAt.toISOString(),
        },
      },
      {
        preserveState: true,
        onSuccess: () => {
          if (posting !== mine) return;
          answered = true;
          clear();
          open = false;
        },
        onError: (errors) => {
          if (posting !== mine) return;
          answered = true;
          posting = null;
          hold();
          phase = 'review';
          progress = null;
          const reason = errors.recorded_at || errors.audio;
          // A refused retry can't tell us whether the first save landed: stay unsure.
          if (retrying) {
            error = `We still can't confirm the first save${reason ? ` (${reason})` : ''}. Check Recordings in the Field before starting another upload.`;
          } else {
            unconfirmed = false;
            error = reason || 'The voice note could not be saved. It is still here; try again.';
          }
        },
        // Cancelled, a network failure, or a response Inertia can't read:
        // neither callback ran, and the recording may or may not exist.
        onFinish: () => {
          if (answered || posting !== mine) return;
          posting = null;
          hold();
          phase = 'review';
          progress = null;
          unconfirmed = true;
          error = retrying
            ? "We still can't confirm the first save. Check Recordings in the Field before starting another upload."
            : "We couldn't confirm the save. Trying again is safe: it can't make a second copy.";
        },
      }
    );
  }

  // Let go of everything: the mic, the take, an upload still in flight. A
  // POST already sent can't be called back, so closing then just hides the
  // dialog; `force` (unmount) releases regardless.
  function discard({ force = false } = {}) {
    if (phase === 'saving' && progress === 1 && !force) return;
    if (attempt) {
      attempt.cancelled = true;
      attempt.xhrs.forEach((xhr) => xhr.abort());
      attempt.fail(CANCELLED);
      attempt = null;
    }
    clearInterval(ticker);
    current?.dispose();
    current = null;
    clear();
  }

  function clear() {
    posting = null;
    letGo();
    if (take?.url) URL.revokeObjectURL(take.url);
    take = null;
    uploaded = null;
    unconfirmed = false;
    reset();
    phase = 'idle';
  }

  function reset() {
    elapsed = 0;
    error = '';
    ended = '';
    progress = null;
  }

  function leave() {
    if (phase === 'review' && !confirm('Discard this voice note?')) return;
    open = false;
  }

  function again() {
    discard();
    start();
  }
</script>

<Dialog.Root bind:open>
  <Dialog.Content
    class="sm:max-w-md"
    showCloseButton={!holding}
    interactOutsideBehavior={holding ? 'ignore' : 'close'}
    escapeKeydownBehavior={holding ? 'ignore' : 'close'}
    data-testid="voice-note-dialog">
    <Dialog.Header>
      <Dialog.Title>Record now</Dialog.Title>
      <Dialog.Description>
        {sharedLine} It's transcribed by ElevenLabs, like any recording brought in.
      </Dialog.Description>
    </Dialog.Header>

    {#if phase === 'starting'}
      <p class="text-sm text-muted-foreground" role="status">Starting the microphone…</p>
      <Dialog.Footer>
        <Button variant="ghost" onclick={() => (open = false)}>Cancel</Button>
      </Dialog.Footer>
    {:else if phase === 'recording'}
      <div class="flex flex-col items-center gap-4 py-4" data-testid="voice-note-live">
        <div class="flex items-center gap-3">
          <span class="relative flex size-3">
            <span class="absolute inline-flex size-full animate-ping rounded-full bg-red-500 opacity-75"></span>
            <span class="relative inline-flex size-3 rounded-full bg-red-600"></span>
          </span>
          <span class="font-mono text-3xl tabular-nums" data-testid="voice-note-timer">{formatElapsed(elapsed)}</span>
        </div>
        <p class="text-sm text-muted-foreground">Recording. Speak whenever you're ready.</p>
        <Button size="lg" variant="destructive" class="w-full sm:w-auto" onclick={stop} data-testid="voice-note-stop">
          Stop
        </Button>
      </div>
    {:else if phase === 'review' || phase === 'saving'}
      <VoiceNoteReview
        {take}
        bind:title
        {ended}
        {error}
        {progress}
        saving={phase === 'saving'}
        retryLabel={error ? 'Try again' : ''}
        onSave={save}
        onDiscard={leave} />
    {:else if phase === 'failed'}
      <p class="text-sm text-destructive" role="alert">{error}</p>
      <Dialog.Footer>
        <Button variant="ghost" onclick={() => (open = false)}>Close</Button>
        <Button onclick={again}>Try again</Button>
      </Dialog.Footer>
    {/if}
  </Dialog.Content>
</Dialog.Root>
