<script>
  import { expiryLabel } from '$lib/voice-note-recovery';

  // The card a failed voice note shows above the mic button (#453): the error, where the
  // recording is, and Retry / Discard (or Dismiss once it is gone). State lives in MicButton.
  let { failure, disabled = false, onretry, ondiscard, ondismiss } = $props();
</script>

<div
  role="alert"
  data-testid="voice-note-recovery"
  data-saved={failure.saved}
  class="absolute bottom-full right-0 z-20 mb-2 w-72 max-w-[calc(100vw-2rem)] rounded-md border border-border bg-background p-3 text-sm shadow-lg">
  {#if failure.saved === 'gone'}
    <p>{failure.error}</p>
    <div class="mt-2 flex justify-end">
      <button type="button" class="rounded-md px-2 py-1 hover:bg-accent" onclick={ondismiss}>Dismiss</button>
    </div>
  {:else}
    <p class="font-medium">Voice note not transcribed</p>
    <p class="mt-1 text-muted-foreground">{failure.error}</p>
    {#if failure.saved === 'saved'}
      <p class="mt-1 text-muted-foreground">
        Your recording is saved{failure.expiresAt ? ` until ${expiryLabel(failure.expiresAt)}` : ''}.
        {#if !failure.persisted}
          This browser could not remember it, so keep this tab open.
        {/if}
      </p>
    {:else if failure.saved === 'unsaved'}
      <p class="mt-1 text-muted-foreground">Not saved yet. Keep this tab open.</p>
    {/if}
    {#if failure.discardError}
      <p class="mt-1 text-destructive">{failure.discardError}</p>
    {/if}
    <div class="mt-2 flex justify-end gap-2">
      <button
        type="button"
        class="rounded-md px-2 py-1 hover:bg-accent disabled:opacity-50"
        disabled={!!failure.busy}
        onclick={ondiscard}>
        {failure.busy === 'discard' ? 'Discarding…' : 'Discard'}
      </button>
      {#if failure.retryable}
        <button
          type="button"
          class="rounded-md bg-primary px-2 py-1 text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
          disabled={!!failure.busy || disabled}
          onclick={onretry}>
          {failure.busy === 'retry' ? 'Retrying…' : 'Retry transcription'}
        </button>
      {/if}
    </div>
  {/if}
</div>
