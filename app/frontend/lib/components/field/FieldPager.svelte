<script>
  // Previous / next through the Field list, with where you are.
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { CaretLeft, CaretRight } from 'phosphor-svelte';

  let { pagination, onPage } = $props();

  const first = $derived((pagination.page - 1) * pagination.per_page + 1);
  const last = $derived(Math.min(pagination.page * pagination.per_page, pagination.total));
</script>

<nav
  class="flex items-center justify-between gap-2 text-xs text-muted-foreground"
  aria-label="Field pages"
  data-testid="field-pager">
  <Button
    size="sm"
    variant="ghost"
    disabled={pagination.page <= 1}
    onclick={() => onPage(pagination.page - 1)}
    aria-label="Previous page">
    <CaretLeft class="size-4" />
  </Button>
  <span data-testid="field-pager-status">
    {first}–{last} of {pagination.total} · page {pagination.page} of {pagination.pages}
  </span>
  <Button
    size="sm"
    variant="ghost"
    disabled={pagination.page >= pagination.pages}
    onclick={() => onPage(pagination.page + 1)}
    aria-label="Next page">
    <CaretRight class="size-4" />
  </Button>
</nav>
