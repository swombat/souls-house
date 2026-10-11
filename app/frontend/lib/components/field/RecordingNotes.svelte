<script>
  // A recording's notes: the meeting's summary and action items, kept with
  // the recording rather than as a separate Field item. Markdown.
  import { router } from '@inertiajs/svelte';
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Streamdown } from 'svelte-streamdown';
  import { mode } from 'mode-watcher';
  import { PencilSimple, Plus } from 'phosphor-svelte';

  const MAX_NOTES_LENGTH = 100000;

  let { recording } = $props();

  let editing = $state(false);
  let draft = $state('');
  let saving = $state(false);
  const shikiTheme = $derived(mode.current === 'dark' ? 'catppuccin-mocha' : 'catppuccin-latte');

  function startEditing() {
    draft = recording.notes || '';
    editing = true;
  }

  function save(event) {
    event.preventDefault();
    saving = true;
    router.patch(
      recording.show_url,
      { field_recording: { notes: draft } },
      {
        preserveScroll: true,
        preserveState: true,
        onSuccess: () => (editing = false),
        onFinish: () => (saving = false),
      }
    );
  }
</script>

{#if editing}
  <Card.Root data-testid="recording-notes-editor">
    <Card.Content class="p-6">
      <form onsubmit={save} class="space-y-3">
        <label for="recording-notes" class="text-sm font-medium">
          Notes <span class="text-muted-foreground font-normal">(Markdown)</span>
        </label>
        <textarea
          id="recording-notes"
          bind:value={draft}
          maxlength={MAX_NOTES_LENGTH}
          rows="16"
          class="w-full rounded-md border border-input bg-background px-3 py-2 text-sm font-mono"></textarea>
        <div class="flex gap-2">
          <Button type="submit" size="sm" disabled={saving}>Save</Button>
          <Button type="button" size="sm" variant="ghost" onclick={() => (editing = false)}>Cancel</Button>
        </div>
      </form>
    </Card.Content>
  </Card.Root>
{:else if recording.notes}
  <Card.Root data-testid="recording-notes">
    <Card.Content class="p-6 space-y-2">
      <div class="flex items-center justify-between gap-2">
        <h2 class="text-sm uppercase tracking-wide text-muted-foreground">Notes</h2>
        <Button size="sm" variant="ghost" onclick={startEditing}><PencilSimple class="size-4" /> Edit</Button>
      </div>
      <div class="prose dark:prose-invert max-w-none">
        <Streamdown
          content={recording.notes}
          parseIncompleteMarkdown={false}
          baseTheme="shadcn"
          {shikiTheme}
          shikiPreloadThemes={['catppuccin-latte', 'catppuccin-mocha']} />
      </div>
    </Card.Content>
  </Card.Root>
{:else}
  <div>
    <Button size="sm" variant="ghost" onclick={startEditing} data-testid="add-recording-notes">
      <Plus class="size-4" /> Add notes
    </Button>
  </div>
{/if}
