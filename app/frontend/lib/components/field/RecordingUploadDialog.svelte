<script>
  import { router } from '@inertiajs/svelte';
  import { DirectUpload } from '@rails/activestorage';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import { formatBytes } from '$lib/field';
  import { formatDuration, guessSpeakers, preflightProblem } from '$lib/field-recordings';

  let {
    open = $bindable(false),
    accountId,
    allowance = null,
    maxBytes = 2 * 1024 * 1024 * 1024,
    maxLabel = '2 GB',
    sharedLine = '',
  } = $props();

  let file = $state(null);
  let title = $state('');
  let note = $state('');
  let speakers = $state('');
  let speakersTouched = $state(false);
  let durationMs = $state(null);
  let tooLarge = $state('');
  let error = $state('');
  let progress = $state(null);
  let busy = $state(false);
  let activeXhr = null;

  const guess = $derived(guessSpeakers(title));
  const warning = $derived(preflightProblem(durationMs, allowance));

  $effect(() => {
    if (!speakersTouched) speakers = guess ? String(guess.count) : '';
  });

  function reset() {
    file = null;
    title = '';
    note = '';
    speakers = '';
    speakersTouched = false;
    durationMs = null;
    tooLarge = '';
    error = '';
    progress = null;
  }

  // Advisory only: the browser reads the length so a long upload that will be
  // refused can be seen before it starts. The server's check decides.
  function readDuration(chosen) {
    durationMs = null;
    const url = URL.createObjectURL(chosen);
    const audio = document.createElement('audio');
    audio.preload = 'metadata';
    const done = () => URL.revokeObjectURL(url);
    audio.onloadedmetadata = () => {
      if (file === chosen && Number.isFinite(audio.duration)) durationMs = Math.round(audio.duration * 1000);
      done();
    };
    audio.onerror = done;
    audio.src = url;
  }

  function choose(event) {
    const chosen = event.currentTarget.files?.[0] || null;
    file = chosen;
    error = '';
    tooLarge = '';
    durationMs = null;
    if (!chosen) return;
    if (chosen.size > maxBytes) {
      tooLarge = `${chosen.name} is ${formatBytes(chosen.size)}. The limit is ${maxLabel}.`;
      return;
    }
    readDuration(chosen);
  }

  function upload(chosen) {
    return new Promise((resolve, reject) => {
      let createXhr = null;
      const delegate = {
        directUploadWillCreateBlobWithXHR: (xhr) => (createXhr = xhr),
        directUploadWillStoreFileWithXHR: (xhr) => {
          activeXhr = xhr;
          xhr.upload.addEventListener('progress', (e) => {
            if (e.lengthComputable) progress = e.loaded / e.total;
          });
        },
      };
      const direct = new DirectUpload(chosen, `/accounts/${accountId}/field/recordings/uploads`, delegate);
      direct.create((failure, blob) => {
        activeXhr = null;
        if (failure) reject(createXhr?.response?.error || 'The upload stopped. Please try again.');
        else resolve(blob);
      });
    });
  }

  async function submit(event) {
    event.preventDefault();
    if (!file || tooLarge || busy) return;
    busy = true;
    error = '';
    progress = 0;
    try {
      const blob = await upload(file);
      const count = parseInt(speakers, 10);
      router.post(
        `/accounts/${accountId}/field/recordings`,
        {
          field_recording: {
            upload_id: blob.signed_id,
            title: title.trim(),
            note: note.trim(),
            expected_speakers: count >= 1 && count <= 32 ? count : null,
          },
        },
        {
          preserveState: true,
          onSuccess: () => {
            open = false;
            reset();
          },
          onError: (errors) => (error = errors.audio || 'The recording could not be brought in. Please try again.'),
          onFinish: () => {
            busy = false;
            progress = null;
          },
        }
      );
    } catch (failure) {
      error = typeof failure === 'string' ? failure : 'The upload stopped. Please try again.';
      busy = false;
      progress = null;
    }
  }

  function cancel() {
    activeXhr?.abort();
    open = false;
  }
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="sm:max-w-lg">
    <Dialog.Header>
      <Dialog.Title>Bring in a recording</Dialog.Title>
      <Dialog.Description>{sharedLine} It's transcribed so you can read it together.</Dialog.Description>
    </Dialog.Header>
    <form onsubmit={submit} class="space-y-4" data-testid="recording-upload-form">
      <div class="space-y-1">
        <Label for="recording-file">Audio or video (up to {maxLabel})</Label>
        <Input id="recording-file" type="file" accept="audio/*,video/*" onchange={choose} required disabled={busy} />
        {#if durationMs != null && !warning}
          <p class="text-xs text-muted-foreground">{formatDuration(durationMs)} long.</p>
        {/if}
      </div>
      <div class="space-y-1">
        <Label for="recording-title">Title</Label>
        <Input
          id="recording-title"
          bind:value={title}
          maxlength={200}
          placeholder={file?.name || 'Venue planning with Priya and Tomás'} />
      </div>
      <div class="space-y-1">
        <Label for="recording-note">Why I'm bringing this <span class="text-muted-foreground">(optional)</span></Label>
        <textarea
          id="recording-note"
          bind:value={note}
          maxlength={2000}
          rows="3"
          class="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"></textarea>
      </div>
      <div class="space-y-1">
        <Label for="recording-speakers">
          How many people are speaking? <span class="text-muted-foreground">(optional)</span>
        </Label>
        <Input
          id="recording-speakers"
          type="number"
          min="1"
          max="32"
          class="w-24"
          bind:value={speakers}
          oninput={() => (speakersTouched = true)} />
        {#if guess && !speakersTouched}
          <p class="text-xs text-muted-foreground">
            Guessed from the title: {guess.reason}. Change it if that's wrong.
          </p>
        {/if}
      </div>
      {#if tooLarge}
        <p class="text-sm text-destructive" role="alert">{tooLarge}</p>
      {:else if warning}
        <p class="text-sm text-amber-700 dark:text-amber-400" role="status" data-testid="recording-preflight">
          {warning} You can still try; the Field checks when it arrives.
        </p>
      {/if}
      {#if progress != null}
        <div class="space-y-1" data-testid="recording-progress">
          <div class="h-2 rounded-full bg-muted overflow-hidden">
            <div class="h-full bg-primary transition-[width]" style="width: {Math.round(progress * 100)}%"></div>
          </div>
          <p class="text-xs text-muted-foreground">
            {progress === 0
              ? 'Getting the file ready…'
              : progress < 1
                ? `Uploading… ${Math.round(progress * 100)}%`
                : 'Uploaded. Bringing it in…'}
          </p>
        </div>
      {/if}
      {#if error}
        <p class="text-sm text-destructive" role="alert">{error}</p>
      {/if}
      <Dialog.Footer>
        <Button type="button" variant="ghost" onclick={cancel}>Cancel</Button>
        <Button type="submit" disabled={!file || !!tooLarge || busy}>
          {busy ? 'Uploading…' : 'Bring it in'}
        </Button>
      </Dialog.Footer>
    </form>
  </Dialog.Content>
</Dialog.Root>
