<script>
  // A finished take, before it is saved: listen back, name it, save or discard.
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import { formatElapsed } from '$lib/mic-recorder.js';

  let {
    take,
    title = $bindable(''),
    ended = '',
    error = '',
    progress = null,
    saving = false,
    retryLabel = '',
    onSave,
    onDiscard,
  } = $props();
</script>

<form class="space-y-4" onsubmit={onSave} data-testid="voice-note-review">
  {#if ended}
    <p class="text-sm text-amber-700 dark:text-amber-400" role="status">{ended}</p>
  {/if}
  <!-- svelte-ignore a11y_media_has_caption -->
  <audio controls src={take?.url} class="w-full" data-testid="voice-note-playback"></audio>
  <p class="text-xs text-muted-foreground">{formatElapsed(take?.durationMs || 0)} long.</p>
  <div class="space-y-1">
    <Label for="voice-note-title">Title</Label>
    <Input id="voice-note-title" bind:value={title} maxlength={200} disabled={saving} />
  </div>
  {#if progress != null}
    <div class="space-y-1" data-testid="voice-note-progress">
      <div class="h-2 overflow-hidden rounded-full bg-muted">
        <div class="h-full bg-primary transition-[width]" style="width: {Math.round(progress * 100)}%"></div>
      </div>
      <p class="text-xs text-muted-foreground">
        {progress < 1 ? `Uploading… ${Math.round(progress * 100)}%` : 'Saving…'}
      </p>
    </div>
  {/if}
  {#if error}
    <p class="text-sm text-destructive" role="alert">{error}</p>
  {/if}
  <Dialog.Footer class="gap-2">
    <Button type="button" variant="ghost" onclick={onDiscard} disabled={saving} data-testid="voice-note-discard"
      >Discard</Button>
    <Button type="submit" disabled={saving} data-testid="voice-note-save">
      {saving ? 'Saving…' : retryLabel || 'Save to Field'}
    </Button>
  </Dialog.Footer>
</form>
