<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import * as Drawer from '$lib/components/shadcn/drawer/index.js';
  import { Spinner } from 'phosphor-svelte';

  // onclosed: called as the drawer closes by any path (Save, Cancel, Esc, a
  // click outside); returns true when it has placed focus itself.
  let { open = $bindable(false), messageId = null, initialContent = '', onsaved, onclosed, onerror } = $props();

  let content = $state('');
  let saving = $state(false);
  let textareaRef = $state(null);

  // Reset content when a new message is opened for editing
  $effect(() => {
    if (open && initialContent) {
      content = initialContent;
    }
  });

  // Open with the cursor after the last character, ready to type.
  function focusAtEnd(event) {
    if (!textareaRef) return;
    event.preventDefault();
    textareaRef.focus();
    const end = textareaRef.value.length;
    textareaRef.setSelectionRange(end, end);
  }

  function returnFocus(event) {
    if (onclosed?.()) event.preventDefault();
  }

  function cancel() {
    open = false;
    content = '';
  }

  async function save() {
    if (saving || !content.trim() || !messageId) return;
    saving = true;

    try {
      const response = await fetch(`/messages/${messageId}`, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
        },
        body: JSON.stringify({ message: { content: content.trim() } }),
      });

      if (response.ok) {
        const trimmedContent = content.trim();
        open = false;
        content = '';
        onsaved?.(messageId, trimmedContent);
        router.reload({ only: ['messages'], preserveScroll: true });
      } else {
        onerror?.('Failed to save message');
      }
    } catch (error) {
      onerror?.('Failed to save message');
    } finally {
      saving = false;
    }
  }
</script>

<Drawer.Root bind:open onClose={() => !saving && cancel()}>
  <Drawer.Content class="max-h-[50vh]" onOpenAutoFocus={focusAtEnd} onCloseAutoFocus={returnFocus}>
    <Drawer.Header>
      <Drawer.Title>Edit Message</Drawer.Title>
    </Drawer.Header>
    <div class="p-4 space-y-4">
      <textarea
        bind:this={textareaRef}
        bind:value={content}
        disabled={saving}
        data-testid="edit-message-text"
        class="w-full min-h-[100px] resize-none border border-input rounded-md px-3 py-2 text-sm bg-background focus:outline-none focus:ring-2 focus:ring-ring disabled:opacity-50"
      ></textarea>
      <div class="flex justify-end gap-2">
        <Button variant="outline" onclick={cancel} disabled={saving}>Cancel</Button>
        <Button onclick={save} disabled={!content.trim() || saving}>
          {#if saving}
            <Spinner size={16} class="mr-2 animate-spin" />
            Saving...
          {:else}
            Save
          {/if}
        </Button>
      </div>
    </div>
  </Drawer.Content>
</Drawer.Root>
