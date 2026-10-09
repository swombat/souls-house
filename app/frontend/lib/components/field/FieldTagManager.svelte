<script>
  // The account's tags: rename (everywhere at once, merging into an existing
  // tag if asked) or delete. People only; residents add and remove tags on
  // items but never change a tag itself.
  import { router } from '@inertiajs/svelte';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';

  // onChanged(oldName, newName) after a rename or merge; newName is null after
  // a delete. The page uses it to keep an active filter pointing at a real
  // tag, and returns true when it navigated (so no reload is needed).
  let { open = $bindable(false), accountId, tags = [], onChanged = () => false } = $props();

  let editingId = $state(null);
  let newName = $state('');
  let error = $state('');
  let busy = $state(false);

  function csrf() {
    return document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || '';
  }

  function reload() {
    router.reload({ only: ['files', 'notes', 'recordings', 'tags', 'search', 'filter_tags'], preserveScroll: true });
  }

  async function rename(tag, merge = false) {
    busy = true;
    error = '';
    try {
      const response = await fetch(`/accounts/${accountId}/field/tags/${tag.id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json', 'X-CSRF-Token': csrf() },
        body: JSON.stringify({ name: newName, merge }),
      });
      const data = await response.json().catch(() => ({}));
      if (response.ok) {
        editingId = null;
        // The page navigates when an active filter follows the change, and
        // that visit reloads everything; otherwise reload here.
        if (!onChanged(tag.name, data.tag?.name || null)) reload();
      } else if (response.status === 409 && !merge) {
        const into = data.existing?.name || newName;
        if (confirm(`"${into}" is already a tag. Move everything tagged "${tag.name}" onto "${into}"?`)) {
          busy = false;
          return rename(tag, true);
        }
      } else {
        error = data.error || 'The tag could not be renamed.';
      }
    } catch {
      error = 'The tag could not be renamed.';
    } finally {
      busy = false;
    }
  }

  async function remove(tag) {
    const things = tag.item_count === 1 ? '1 item' : `${tag.item_count} items`;
    if (!confirm(`Delete the tag "${tag.name}"? It comes off ${things}, for everyone. The items stay.`)) return;
    busy = true;
    error = '';
    try {
      const response = await fetch(`/accounts/${accountId}/field/tags/${tag.id}`, {
        method: 'DELETE',
        headers: { Accept: 'application/json', 'X-CSRF-Token': csrf() },
      });
      if (response.ok) {
        if (!onChanged(tag.name, null)) reload();
      } else error = 'The tag could not be deleted.';
    } catch {
      error = 'The tag could not be deleted.';
    } finally {
      busy = false;
    }
  }
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="sm:max-w-lg">
    <Dialog.Header>
      <Dialog.Title>Tags</Dialog.Title>
      <Dialog.Description>
        Renaming or deleting a tag changes every item that carries it, for everyone in this account. Residents can add
        and remove tags on items, but only people can change a tag itself.
      </Dialog.Description>
    </Dialog.Header>
    {#if tags.length === 0}
      <p class="text-sm text-muted-foreground">No tags yet. Add one from any item.</p>
    {:else}
      <ul class="divide-y max-h-96 overflow-y-auto" data-testid="field-tag-manager">
        {#each tags as tag (tag.id)}
          <li class="flex items-center gap-2 py-2">
            {#if editingId === tag.id}
              <form
                class="flex flex-1 gap-2"
                onsubmit={(event) => {
                  event.preventDefault();
                  rename(tag);
                }}>
                <input
                  bind:value={newName}
                  maxlength={50}
                  aria-label={`New name for ${tag.name}`}
                  class="h-8 flex-1 rounded-md border border-input bg-background px-2 text-sm" />
                <Button size="sm" type="submit" disabled={busy || !newName.trim()}>Rename</Button>
                <Button size="sm" variant="ghost" type="button" onclick={() => (editingId = null)}>Cancel</Button>
              </form>
            {:else}
              <span class="flex-1 text-sm">{tag.name}</span>
              <span class="text-xs text-muted-foreground">{tag.item_count}</span>
              <Button
                size="sm"
                variant="ghost"
                onclick={() => {
                  editingId = tag.id;
                  newName = tag.name;
                }}>Rename</Button>
              <Button size="sm" variant="ghost" disabled={busy} onclick={() => remove(tag)}>Delete</Button>
            {/if}
          </li>
        {/each}
      </ul>
    {/if}
    {#if error}
      <p class="text-sm text-destructive" role="alert">{error}</p>
    {/if}
  </Dialog.Content>
</Dialog.Root>
