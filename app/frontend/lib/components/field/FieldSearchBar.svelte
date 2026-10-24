<script>
  // The Field's search box and tag filter. The page owns the URL; this only
  // says what was asked for.
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { MagnifyingGlass, Tag } from 'phosphor-svelte';

  let { query = '', filterTags = [], tags = [], onSearch, onToggleTag, onManage } = $props();

  let searchText = $state('');
  $effect(() => {
    searchText = query;
  });

  function submit(event) {
    event.preventDefault();
    onSearch(searchText.trim());
  }

  function clear() {
    searchText = '';
    onSearch('');
  }
</script>

<form onsubmit={submit} class="mb-3 flex gap-2" role="search">
  <div class="relative flex-1">
    <MagnifyingGlass class="absolute left-3 top-1/2 -translate-y-1/2 size-4 text-muted-foreground" />
    <Input
      bind:value={searchText}
      maxlength={200}
      placeholder={'Search titles, notes and transcripts. "Quote a phrase", -leave out'}
      aria-label="Search the Field"
      class="pl-9"
      data-testid="field-search-input" />
  </div>
  <Button type="submit" variant="secondary" disabled={!searchText.trim()}>Search</Button>
  {#if query}
    <Button type="button" variant="ghost" onclick={clear}>Clear</Button>
  {/if}
</form>

<div class="mb-4 flex flex-wrap items-center gap-1.5" data-testid="field-tag-filter">
  <Tag class="size-4 text-muted-foreground" />
  {#if tags.length === 0}
    <span class="text-xs text-muted-foreground">No tags yet. Add one to any item.</span>
  {/if}
  {#each tags as t (t.id)}
    <button
      type="button"
      onclick={() => onToggleTag(t.name)}
      aria-pressed={filterTags.includes(t.name)}
      class="rounded-full border px-2 py-0.5 text-xs transition-colors {filterTags.includes(t.name)
        ? 'border-primary bg-primary text-primary-foreground'
        : 'border-input hover:bg-muted'}">
      {t.name} <span class="opacity-70">{t.item_count}</span>
    </button>
  {/each}
  <!-- A filter whose tag no longer exists (renamed or deleted elsewhere) still
       gets a chip, so it can always be cleared. -->
  {#each filterTags.filter((name) => !tags.some((t) => t.name === name)) as name (name)}
    <button
      type="button"
      onclick={() => onToggleTag(name)}
      aria-pressed="true"
      title="This tag no longer exists. Click to stop filtering by it."
      class="rounded-full border border-dashed border-primary px-2 py-0.5 text-xs line-through">
      {name}
    </button>
  {/each}
  {#if tags.length}
    <Button size="sm" variant="ghost" class="h-6 text-xs" onclick={onManage}>Manage tags</Button>
  {/if}
</div>
