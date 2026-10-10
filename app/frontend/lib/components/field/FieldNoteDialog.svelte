<script>
  // The New note dialog: a name and Markdown, saved as a Field note.
  import { router } from '@inertiajs/svelte';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';

  let { open = $bindable(false), accountId, sharedLine } = $props();

  let noteName = $state('');
  let noteContent = $state('');
  let creatingNote = $state(false);
  let noteError = $state('');

  function submitNote(event) {
    event.preventDefault();
    if (!noteName.trim()) return;
    creatingNote = true;
    noteError = '';
    router.post(
      `/accounts/${accountId}/whiteboards`,
      { whiteboard: { name: noteName.trim(), content: noteContent } },
      {
        preserveState: true,
        onSuccess: () => {
          open = false;
          noteName = '';
          noteContent = '';
        },
        onError: (errors) => (noteError = errors.name || 'The note could not be saved. Please try again.'),
        onFinish: () => (creatingNote = false),
      }
    );
  }
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="sm:max-w-lg">
    <Dialog.Header>
      <Dialog.Title>New note</Dialog.Title>
      <Dialog.Description>{sharedLine} Residents can read and edit notes.</Dialog.Description>
    </Dialog.Header>
    <form onsubmit={submitNote} class="space-y-4">
      <div class="space-y-1">
        <Label for="note-name">Name</Label>
        <Input id="note-name" bind:value={noteName} maxlength={100} required />
      </div>
      <div class="space-y-1">
        <Label for="note-content">Note <span class="text-muted-foreground">(Markdown)</span></Label>
        <textarea
          id="note-content"
          bind:value={noteContent}
          rows="8"
          class="w-full rounded-md border border-input bg-background px-3 py-2 text-sm font-mono"></textarea>
      </div>
      {#if noteError}
        <p class="text-sm text-destructive" role="alert">{noteError}</p>
      {/if}
      <Dialog.Footer>
        <Button type="button" variant="ghost" onclick={() => (open = false)}>Cancel</Button>
        <Button type="submit" disabled={!noteName.trim() || creatingNote}>Create note</Button>
      </Dialog.Footer>
    </form>
  </Dialog.Content>
</Dialog.Root>
