<script>
  import FieldSummary from '$lib/components/field/FieldSummary.svelte';
  import { tick } from 'svelte';
  import { Link, router } from '@inertiajs/svelte';
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { Button, buttonVariants } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import { ArrowClockwise, PencilSimple, Scroll, Trash } from 'phosphor-svelte';
  import { formatBytes, formatWhen } from '$lib/field';
  import { formatDuration, recordingStatusLine } from '$lib/field-recordings';

  let { recording } = $props();

  let editing = $state(false);
  let title = $state('');
  let note = $state('');
  let recordedOn = $state('');
  let saving = $state(false);

  const statusLine = $derived(recordingStatusLine(recording));
  const troubled = $derived(recording.status === 'rejected' || recording.status === 'failed');

  async function startEditing({ focusTitle = false } = {}) {
    title = recording.title || '';
    note = recording.note || '';
    recordedOn = recordedDay(recording.recorded_at);
    editing = true;
    if (!focusTitle) return;
    await tick();
    const input = document.getElementById('recording-edit-title');
    input?.focus();
    input?.select();
  }

  // The title is a shortcut to the same form as Edit: double-click it with a
  // mouse, or press and hold it on a touch screen.
  const HOLD_MS = 500;
  const HOLD_SLOP_PX = 10;
  let hold = null;
  let touching = false;

  function titlePointerDown(event) {
    touching = event.pointerType === 'touch';
    if (!touching) return;
    clearHold();
    hold = {
      x: event.clientX,
      y: event.clientY,
      timer: setTimeout(() => {
        hold = null;
        window.getSelection?.()?.removeAllRanges();
        startEditing({ focusTitle: true });
      }, HOLD_MS),
    };
  }

  // A finger drifting a little is still a hold; scrolling is not.
  function titlePointerMove(event) {
    if (hold && Math.hypot(event.clientX - hold.x, event.clientY - hold.y) > HOLD_SLOP_PX) clearHold();
  }

  function clearHold() {
    if (hold) clearTimeout(hold.timer);
    hold = null;
  }

  function titleDoubleClick() {
    // A double-click also selects a word; the form replaces the heading anyway.
    window.getSelection?.()?.removeAllRanges();
    startEditing({ focusTitle: true });
  }

  // The day part of recorded_at as the server sent it (in the app's zone),
  // for the date input.
  function recordedDay(value) {
    return value ? value.slice(0, 10) : '';
  }

  function save(event) {
    event.preventDefault();
    saving = true;
    const changes = { title: title.trim(), note: note.trim() };
    // Only a changed date is sent, so saving a title keeps a recorded time
    // of day rather than resetting it to midnight.
    if (recordedOn !== recordedDay(recording.recorded_at)) changes.recorded_at = recordedOn;
    router.patch(
      recording.show_url,
      { field_recording: changes },
      {
        preserveScroll: true,
        preserveState: true,
        onSuccess: () => (editing = false),
        onFinish: () => (saving = false),
      }
    );
  }

  function retry() {
    router.post(`${recording.show_url}/retry`, {}, { preserveScroll: true });
  }

  function remove() {
    const message =
      `Delete "${recording.title}" from the Field? It disappears for everyone, people and residents. ` +
      'Deleting does not reach anything a resident has already read: quotes in chats and things kept in ' +
      'memory stay where they are.' +
      (recording.dispatched ? " It has started transcribing, so deleting it doesn't give its minutes back." : '');
    if (!confirm(message)) return;
    router.delete(recording.show_url);
  }
</script>

<Card.Root data-testid="field-recording-viewer">
  <Card.Content class="p-6 space-y-4">
    {#if editing}
      <form onsubmit={save} class="space-y-3">
        <div class="space-y-1">
          <Label for="recording-edit-title">Title</Label>
          <Input id="recording-edit-title" bind:value={title} maxlength={200} required />
        </div>
        <div class="space-y-1">
          <Label for="recording-edit-note">Why I'm bringing this</Label>
          <textarea
            id="recording-edit-note"
            bind:value={note}
            maxlength={2000}
            rows="3"
            class="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"></textarea>
        </div>
        <div class="space-y-1">
          <Label for="recording-edit-recorded-on">Recorded on</Label>
          <Input
            id="recording-edit-recorded-on"
            type="date"
            class="w-44"
            bind:value={recordedOn}
            data-testid="recording-edit-recorded-on" />
          <p class="text-xs text-muted-foreground">Leave empty to order it by when it was brought in.</p>
        </div>
        <div class="flex gap-2">
          <Button type="submit" size="sm" disabled={saving || !title.trim()}>Save</Button>
          <Button type="button" size="sm" variant="ghost" onclick={() => (editing = false)}>Cancel</Button>
        </div>
      </form>
    {:else}
      <div>
        <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
        <h2
          class="text-xl font-semibold break-words cursor-text pointer-coarse:select-none pointer-coarse:[-webkit-touch-callout:none]"
          title="Double-click to edit"
          data-testid="field-recording-title"
          ondblclick={titleDoubleClick}
          onpointerdown={titlePointerDown}
          onpointermove={titlePointerMove}
          onpointerup={clearHold}
          onpointercancel={clearHold}
          oncontextmenu={(event) => touching && event.preventDefault()}>
          {recording.title}
        </h2>
        <p class="text-sm text-muted-foreground mt-1">
          {#if recording.uploader_name}
            Brought by {recording.uploader_name}{recording.uploader_kind === 'resident' ? ' (resident)' : ''} ·
          {/if}
          {#if recording.recorded_at}Recorded {formatWhen(recording.recorded_at)} ·
          {/if}{formatWhen(recording.created_at)}
        </p>
      </div>
      {#if recording.summary_long}
        <FieldSummary
          text={recording.summary_long}
          pending={recording.summary_pending}
          failed={recording.summary_failed}
          freshness={recording.summary_freshness}
          url={recording.resummarize_url}
          testid="field-recording-summary" />
      {/if}
      {#if recording.note}
        <div>
          <p class="text-xs uppercase tracking-wide text-muted-foreground mb-1">Why I'm bringing this</p>
          <p class="whitespace-pre-wrap">{recording.note}</p>
        </div>
      {/if}
      {#if recording.notes}
        <div data-testid="field-recording-notes">
          <p class="text-xs uppercase tracking-wide text-muted-foreground mb-1">Notes</p>
          <p class="whitespace-pre-wrap text-sm line-clamp-6">{recording.notes}</p>
        </div>
      {/if}
    {/if}

    <p class="text-sm {troubled ? 'text-destructive' : ''}" data-testid="field-recording-status">
      {#if recording.status === 'ready'}
        {recording.speaker_names?.length ? `Speaking: ${statusLine}` : 'Transcript ready.'}
      {:else}
        {statusLine}
      {/if}
    </p>

    <p class="text-sm text-muted-foreground">
      {[
        recording.duration_ms != null ? formatDuration(recording.duration_ms) : null,
        recording.expected_speakers ? `${recording.expected_speakers} expected speakers` : null,
        recording.filename,
        recording.byte_size != null ? formatBytes(recording.byte_size) : null,
      ]
        .filter(Boolean)
        .join(' · ')}
    </p>

    <div class="flex flex-wrap gap-2">
      {#if recording.status === 'ready'}
        <Link href={recording.show_url} class={buttonVariants({ size: 'sm' })} data-testid="open-transcript">
          <Scroll class="size-4" /> Open transcript
        </Link>
      {:else if recording.notes}
        <!-- The notes are clamped here; the recording page shows them whole, ready or not. -->
        <Link href={recording.show_url} class={buttonVariants({ size: 'sm' })} data-testid="open-recording-notes">
          <Scroll class="size-4" /> Open notes
        </Link>
      {/if}
      {#if recording.retryable}
        <Button size="sm" variant="outline" onclick={retry}>
          <ArrowClockwise class="size-4" /> Try again
        </Button>
      {/if}
      {#if !editing}
        <Button size="sm" variant="ghost" onclick={() => startEditing()}>
          <PencilSimple class="size-4" /> Edit
        </Button>
      {/if}
      <Button size="sm" variant="ghost" onclick={remove}>
        <Trash class="size-4" /> Delete
      </Button>
    </div>
  </Card.Content>
</Card.Root>
