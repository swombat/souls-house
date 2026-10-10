<script>
  // One page of the Field list. Past COMPACT_AFTER items in the tab it turns
  // into one-line rows, with a pager above and below when there's more than
  // one page.
  import FieldItemCard from '$lib/components/field/FieldItemCard.svelte';
  import FieldItemRow from '$lib/components/field/FieldItemRow.svelte';
  import FieldPager from '$lib/components/field/FieldPager.svelte';

  const COMPACT_AFTER = 10;

  let { items = [], pagination, filterTags = [], currentKey = null, onSelect, onPage } = $props();

  const compact = $derived(pagination.total > COMPACT_AFTER);
</script>

{#if items.length === 0}
  <p class="text-sm text-muted-foreground p-4">
    {filterTags.length ? `Nothing here carries ${filterTags.join(' and ')}.` : 'Nothing here yet.'}
  </p>
{/if}
{#if pagination.pages > 1}
  <FieldPager {pagination} {onPage} />
{/if}
{#if compact}
  <div class="rounded-md border divide-y" data-testid="field-compact-list">
    {#each items as item (item.key)}
      <FieldItemRow {item} selected={currentKey === item.key} {onSelect} />
    {/each}
  </div>
{:else}
  {#each items as item (item.key)}
    <FieldItemCard {item} selected={currentKey === item.key} {onSelect} />
  {/each}
{/if}
{#if pagination.pages > 1}
  <FieldPager {pagination} {onPage} />
{/if}
