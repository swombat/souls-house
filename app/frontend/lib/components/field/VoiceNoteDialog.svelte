<script>
  // Record now: speak straight into the Field. Opening the dialog starts the
  // microphone (the browser asks first if it needs to). Stop ends the take and
  // shows it for listening; Save to Field sends it through the same upload and
  // transcription as a recording brought in from a file. While there is a live
  // or unsaved take the dialog can only be left by Save or Discard: Escape, a
  // tap outside and the X are off, so a stray tap can't lose the thought.
  //
  // If the browser stops the microphone on its own (an iPhone screen locking,
  // a call coming in), the take ends where it stopped and goes to review with
  // what was captured; the timer never runs on after the recording has.
  import { untrack } from 'svelte';
  import { router } from '@inertiajs/svelte';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import { directUpload } from '$lib/field-direct-upload';
  import { holdForRecording } from '$lib/recording-guard';
  import {
    abandonRecorder,
    formatElapsed,
    micErrorMessage,
    recorderOptions,
    stopStream,
    voiceNoteFile,
    voiceNoteTitle,
  } from '$lib/mic-recorder.js';

  let { open = $bindable(false), accountId, sharedLine = '' } = $props();

  // starting → recording → review → saving; or failed when the mic can't start.
  let phase = $state('idle');
  let elapsed = $state(0);
  let title = $state('');
  let error = $state('');
  let progress = $state(null);
  let take = $state(null); // { file, url, startedAt, durationMs }
  let ended = $state(''); // why a take ended on its own, if it did

  let recorder = null;
  let releaseHold = null;
  let stopAsked = false;
  let chunks = [];
  let startedAt = null;
  let ticker = null;
  let attempt = null;
  const CANCELLED = Symbol('cancelled');

  const holding = $derived(phase === 'recording' || phase === 'review' || phase === 'saving' || phase === 'starting');

  $effect(() => {
    if (open) untrack(() => phase === 'idle' && start());
    else untrack(() => discard());
  });

  async function start() {
    reset();
    phase = 'starting';
    let stream;
    try {
      if (!navigator.mediaDevices?.getUserMedia) throw new Error('unsupported');
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (err) {
      if (!open) return;
      phase = 'failed';
      error =
        err?.message === 'unsupported'
          ? "This browser can't record here. Try Bring in a recording."
          : micErrorMessage(err);
      return;
    }
    if (!open || phase !== 'starting') {
      stopStream(stream);
      return;
    }
    let current;
    try {
      current = new MediaRecorder(stream, recorderOptions());
    } catch {
      stopStream(stream);
      phase = 'failed';
      error = 'Could not start recording';
      return;
    }
    recorder = current;
    // The take lives only in this page until it is saved: hold off the
    // background reloads (and a deploy's full-page swap) that would drop it,
    // and ask before the person navigates away.
    releaseHold ??= holdForRecording();
    chunks = [];
    current.ondataavailable = (event) => {
      if (event.data?.size) chunks.push(event.data);
    };
    current.onstop = () => finish(current);
    current.onerror = () => endOnItsOwn(current, 'The recording stopped unexpectedly. What was captured is below.');
    stream.getAudioTracks().forEach((track) => {
      track.onended = () =>
        endOnItsOwn(current, 'The microphone stopped (the screen may have locked). What was captured is below.');
    });
    startedAt = new Date();
    title = voiceNoteTitle(startedAt);
    // A timeslice keeps what has been said in hand even if the take is cut off.
    current.start(1000);
    phase = 'recording';
    ticker = setInterval(() => {
      if (current.state === 'recording') elapsed = Date.now() - startedAt.getTime();
      else if (recorder === current && phase === 'recording')
        endOnItsOwn(current, 'The recording stopped. What was captured is below.');
    }, 250);
  }

  function stop() {
    if (!recorder || phase !== 'recording') return;
    clearInterval(ticker);
    stopAsked = true;
    if (recorder.state !== 'inactive') recorder.stop();
    else finish(recorder);
  }

  function endOnItsOwn(current, reason) {
    if (recorder !== current || phase !== 'recording') return;
    ended = reason;
    stop();
  }

  function finish(current) {
    if (recorder !== current) return;
    clearInterval(ticker);
    stopStream(current.stream);
    recorder = null;
    if (phase !== 'recording') return;
    elapsed = Date.now() - startedAt.getTime();
    // Safari can end a take without any track event (the screen locked).
    if (!stopAsked && !ended) ended = 'The recording stopped on its own. What was captured is below.';
    if (!chunks.length) {
      releaseHold?.();
      releaseHold = null;
      phase = 'failed';
      error = 'Nothing was recorded. Please try again.';
      return;
    }
    const file = voiceNoteFile(chunks, current.mimeType, title);
    take = { file, url: URL.createObjectURL(file), startedAt, durationMs: elapsed };
    phase = 'review';
  }

  async function save(event) {
    event?.preventDefault();
    if (!take || phase !== 'review') return;
    const name = title.trim() || voiceNoteTitle(take.startedAt);
    const file = voiceNoteFile([take.file], take.file.type, name);
    const current = { cancelled: false, posting: false, xhrs: [], createXhr: null, fail: () => {} };
    attempt = current;
    phase = 'saving';
    error = '';
    progress = 0;
    let blob;
    try {
      blob = await directUpload(file, `/accounts/${accountId}/field/recordings/uploads`, current, (fraction) => {
        if (attempt === current) progress = fraction;
      });
    } catch (failure) {
      if (failure === CANCELLED || current.cancelled) return;
      attempt = null;
      // The take stays: Save again retries with the same audio.
      error = typeof failure === 'string' ? failure : 'The upload stopped. Your voice note is still here; try again.';
      phase = 'review';
      progress = null;
      return;
    }
    if (current.cancelled || attempt !== current) return;
    current.posting = true;
    progress = 1;
    // Our own save is not leaving the page: trade the hold that asks
    // "discard the recording?" for a quiet one until the save lands.
    const quiet = holdForRecording({ warn: false });
    releaseHold?.();
    releaseHold = quiet;
    router.post(
      `/accounts/${accountId}/field/recordings`,
      {
        field_recording: {
          upload_id: blob.signed_id,
          title: name,
          note: '',
          expected_speakers: 1,
          recorded_at: take.startedAt.toISOString(),
        },
      },
      {
        preserveState: true,
        onSuccess: () => {
          attempt = null;
          clear();
          open = false;
        },
        onError: (errors) => {
          attempt = null;
          // The take is still only here: ask again before anyone leaves.
          const warning = holdForRecording();
          releaseHold?.();
          releaseHold = warning;
          error =
            errors.recorded_at || errors.audio || 'The voice note could not be saved. It is still here; try again.';
          phase = 'review';
          progress = null;
        },
      }
    );
  }

  // Leave without keeping anything: stop the mic, drop the take, abandon an
  // upload still in flight. A POST already sent can't be called back.
  function discard() {
    if (attempt?.posting) return;
    if (attempt) {
      attempt.cancelled = true;
      attempt.xhrs.forEach((xhr) => xhr.abort());
      attempt.fail(CANCELLED);
      attempt = null;
    }
    clearInterval(ticker);
    abandonRecorder(recorder);
    recorder = null;
    clear();
  }

  function clear() {
    releaseHold?.();
    releaseHold = null;
    if (take?.url) URL.revokeObjectURL(take.url);
    take = null;
    reset();
    phase = 'idle';
  }

  function reset() {
    chunks = [];
    stopAsked = false;
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
          <span class="font-mono text-3xl tabular-nums" data-testid="voice-note-timer" aria-live="off"
            >{formatElapsed(elapsed)}</span>
        </div>
        <p class="text-sm text-muted-foreground">Recording. Speak whenever you're ready.</p>
        <Button size="lg" variant="destructive" class="w-full sm:w-auto" onclick={stop} data-testid="voice-note-stop">
          Stop
        </Button>
      </div>
    {:else if phase === 'review' || phase === 'saving'}
      <form class="space-y-4" onsubmit={save} data-testid="voice-note-review">
        {#if ended}
          <p class="text-sm text-amber-700 dark:text-amber-400" role="status">{ended}</p>
        {/if}
        <!-- svelte-ignore a11y_media_has_caption -->
        <audio controls src={take?.url} class="w-full" data-testid="voice-note-playback"></audio>
        <p class="text-xs text-muted-foreground">{formatElapsed(take?.durationMs || 0)} long.</p>
        <div class="space-y-1">
          <Label for="voice-note-title">Title</Label>
          <Input id="voice-note-title" bind:value={title} maxlength={200} disabled={phase === 'saving'} />
        </div>
        {#if progress != null}
          <div class="space-y-1" data-testid="voice-note-progress">
            <div class="h-2 overflow-hidden rounded-full bg-muted">
              <div class="h-full bg-primary transition-[width]" style="width: {Math.round(progress * 100)}%"></div>
            </div>
            <p class="text-xs text-muted-foreground">
              {progress < 1 ? `Saving… ${Math.round(progress * 100)}%` : 'Saved. Bringing it in…'}
            </p>
          </div>
        {/if}
        {#if error}
          <p class="text-sm text-destructive" role="alert">{error}</p>
        {/if}
        <Dialog.Footer class="gap-2">
          <Button
            type="button"
            variant="ghost"
            onclick={leave}
            disabled={phase === 'saving'}
            data-testid="voice-note-discard">Discard</Button>
          <Button type="submit" disabled={phase === 'saving'} data-testid="voice-note-save">
            {phase === 'saving' ? 'Saving…' : error ? 'Try again' : 'Save to Field'}
          </Button>
        </Dialog.Footer>
      </form>
    {:else if phase === 'failed'}
      <p class="text-sm text-destructive" role="alert">{error}</p>
      <Dialog.Footer>
        <Button variant="ghost" onclick={() => (open = false)}>Close</Button>
        <Button onclick={again}>Try again</Button>
      </Dialog.Footer>
    {/if}
  </Dialog.Content>
</Dialog.Root>
