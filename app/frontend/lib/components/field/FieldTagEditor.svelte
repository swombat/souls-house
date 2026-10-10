<script>
  // Tags on one Field item: chips to remove, a box to add. A name that isn't
  // a tag yet becomes one. Changing a tag itself (rename, delete) is the tag
  // manager's job, not this.
  import { router } from '@inertiajs/svelte';
  import { X } from 'phosphor-svelte';

  let { accountId, itemKey, tags = [], allTags = [] } = $props();

  let adding = $state('');
  let busy = $state(false);
  let error = $state('');
  const listId = $derived(`field-tag-options-${itemKey}`);
  const options = $derived(allTags.map((tag) => tag.name).filter((name) => !tags.includes(name)));

  async function change(body) {
    busy = true;
    error = '';
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content');
    try {
      const response = await fetch(`/accounts/${accountId}/field/item_tags`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json', 'X-CSRF-Token': csrfToken || '' },
        body: JSON.stringify({ item: itemKey, ...body }),
      });
      if (response.ok) {
        adding = '';
        router.reload({ only: ['items', 'current_item', 'counts', 'pagination', 'tags', 'search'], preserveScroll: true });
      } else {
        const data = await response.json().catch(() => ({}));
        error = data.error || 'The tags could not be changed.';
      }
    } catch {
      error = 'The tags could not be changed.';
    } finally {
      busy = false;
    }
  }

  function submit(event) {
    event.preventDefault();
    const names = adding
      .split(',')
      .map((name) => name.trim())
      .filter(Boolean);
    if (names.length) change({ add: names });
  }
</script>

<div class="flex flex-wrap items-center gap-1.5" data-testid="field-tag-editor">
  {#each tags as name (name)}
    <span class="inline-flex items-center gap-1 rounded-full bg-muted px-2 py-0.5 text-xs" data-testid="field-item-tag">
      {name}
      <button
        type="button"
        class="text-muted-foreground hover:text-foreground"
        aria-label={`Remove tag ${name}`}
        disabled={busy}
        onclick={() => change({ remove: [name] })}>
        <X class="size-3" />
      </button>
    </span>
  {/each}
  <form onsubmit={submit} class="inline-flex">
    <input
      bind:value={adding}
      list={listId}
      maxlength={200}
      placeholder={tags.length ? 'Add tag' : 'Add a tag, e.g. life'}
      aria-label="Add a tag"
      disabled={busy}
      class="h-6 w-32 rounded-full border border-input bg-background px-2 text-xs"
      data-testid="field-tag-input" />
    <datalist id={listId}>
      {#each options as name (name)}
        <option value={name}></option>
      {/each}
    </datalist>
  </form>
  {#if error}
    <span class="text-xs text-destructive" role="alert">{error}</span>
  {/if}
</div>
