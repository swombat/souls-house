# Pagination Component

## Installation

```bash
bunx shadcn-svelte@latest add pagination
```

## Usage

```svelte
<script>
  import * as Pagination from "$lib/components/ui/pagination";
  
  let count = 100;
  let perPage = 10;
  let siblingCount = 1;
  let currentPage = 1;
</script>

<!-- Basic pagination -->
<Pagination.Root 
  {count} 
  {perPage} 
  {siblingCount} 
  let:pages 
  let:currentPage
>
  <Pagination.Content>
    <Pagination.Item>
      <Pagination.PrevButton />
    </Pagination.Item>
    
    {#each pages as page (page.key)}
      {#if page.type === "ellipsis"}
        <Pagination.Item>
          <Pagination.Ellipsis />
        </Pagination.Item>
      {:else}
        <Pagination.Item>
          <Pagination.Link {page} isActive={currentPage == page.value}>
            {page.value}
          </Pagination.Link>
        </Pagination.Item>
      {/if}
    {/each}
    
    <Pagination.Item>
      <Pagination.NextButton />
    </Pagination.Item>
  </Pagination.Content>
</Pagination.Root>

<!-- Controlled pagination -->
<script>
  let page = 1;
  
  function handlePageChange(newPage) {
    page = newPage;
    // Fetch new data here
    loadData(newPage);
  }
</script>

<Pagination.Root 
  count={500} 
  perPage={20} 
  bind:page
  onPageChange={handlePageChange}
  let:pages 
  let:currentPage
>
  <Pagination.Content>
    <Pagination.Item>
      <Pagination.PrevButton>
        <ChevronLeft class="h-4 w-4" />
        Previous
      </Pagination.PrevButton>
    </Pagination.Item>
    
    {#each pages as page (page.key)}
      {#if page.type === "ellipsis"}
        <Pagination.Item>
          <Pagination.Ellipsis />
        </Pagination.Item>
      {:else}
        <Pagination.Item>
          <Pagination.Link {page} isActive={currentPage == page.value}>
            {page.value}
          </Pagination.Link>
        </Pagination.Item>
      {/if}
    {/each}
    
    <Pagination.Item>
      <Pagination.NextButton>
        Next
        <ChevronRight class="h-4 w-4" />
      </Pagination.NextButton>
    </Pagination.Item>
  </Pagination.Content>
</Pagination.Root>

<!-- Simple pagination -->
<Pagination.Root count={50} perPage={10} let:pages let:currentPage>
  <Pagination.Content>
    <Pagination.Item>
      <Pagination.PrevButton>Previous</Pagination.PrevButton>
    </Pagination.Item>
    
    <div class="flex items-center gap-1">
      Page {currentPage} of {Math.ceil(count / perPage)}
    </div>
    
    <Pagination.Item>
      <Pagination.NextButton>Next</Pagination.NextButton>
    </Pagination.Item>
  </Pagination.Content>
</Pagination.Root>

<!-- Pagination with page size selector -->
<script>
  let totalItems = 250;
  let currentPage = 1;
  let pageSize = 10;
  
  $: totalPages = Math.ceil(totalItems / pageSize);
</script>

<div class="flex items-center justify-between">
  <div class="flex items-center gap-2">
    <span class="text-sm text-muted-foreground">Rows per page:</span>
    <Select.Root bind:selected={pageSize}>
      <Select.Trigger class="w-16">
        <Select.Value />
      </Select.Trigger>
      <Select.Content>
        <Select.Item value={10}>10</Select.Item>
        <Select.Item value={20}>20</Select.Item>
        <Select.Item value={50}>50</Select.Item>
        <Select.Item value={100}>100</Select.Item>
      </Select.Content>
    </Select.Root>
  </div>
  
  <Pagination.Root 
    count={totalItems} 
    perPage={pageSize} 
    bind:page={currentPage}
    let:pages 
    let:currentPage
  >
    <Pagination.Content>
      <Pagination.Item>
        <Pagination.PrevButton />
      </Pagination.Item>
      
      {#each pages as page (page.key)}
        {#if page.type === "ellipsis"}
          <Pagination.Item>
            <Pagination.Ellipsis />
          </Pagination.Item>
        {:else}
          <Pagination.Item>
            <Pagination.Link {page} isActive={currentPage == page.value}>
              {page.value}
            </Pagination.Link>
          </Pagination.Item>
        {/if}
      {/each}
      
      <Pagination.Item>
        <Pagination.NextButton />
      </Pagination.Item>
    </Pagination.Content>
  </Pagination.Root>
</div>

<!-- Pagination with item count display -->
<div class="flex items-center justify-between">
  <div class="text-sm text-muted-foreground">
    Showing {((currentPage - 1) * pageSize) + 1} to {Math.min(currentPage * pageSize, totalItems)} of {totalItems} results
  </div>
  
  <Pagination.Root 
    count={totalItems} 
    perPage={pageSize} 
    bind:page={currentPage}
    let:pages 
    let:currentPage
  >
    <Pagination.Content>
      <Pagination.Item>
        <Pagination.PrevButton />
      </Pagination.Item>
      
      {#each pages.slice(0, 3) as page (page.key)}
        <Pagination.Item>
          <Pagination.Link {page} isActive={currentPage == page.value}>
            {page.value}
          </Pagination.Link>
        </Pagination.Item>
      {/each}
      
      {#if pages.length > 3}
        <Pagination.Item>
          <Pagination.Ellipsis />
        </Pagination.Item>
      {/if}
      
      <Pagination.Item>
        <Pagination.NextButton />
      </Pagination.Item>
    </Pagination.Content>
  </Pagination.Root>
</div>
```

## Components

- `Pagination.Root` - Pagination container and logic
- `Pagination.Content` - Content container for pagination elements
- `Pagination.Item` - Individual pagination item wrapper
- `Pagination.Link` - Page number link
- `Pagination.PrevButton` - Previous page button
- `Pagination.NextButton` - Next page button
- `Pagination.Ellipsis` - Ellipsis for truncated pages

## Props

### Pagination.Root
- `count` - Total number of items
- `perPage` - Number of items per page
- `siblingCount` - Number of sibling pages shown around current page (default: 1)
- `page` - Current active page (controlled)
- `onPageChange` - Callback when page changes
- `class` - Additional CSS classes

### Pagination.Link
- `page` - Page object with value and key
- `isActive` - Whether this page is currently active
- `class` - Additional CSS classes

### Pagination.PrevButton / Pagination.NextButton
- `class` - Additional CSS classes

## Patterns

### Server-side pagination
```svelte
<script>
  let currentPage = 1;
  let totalItems = 0;
  let data = [];
  let loading = false;
  
  async function loadPage(page) {
    loading = true;
    try {
      const response = await fetch(`/api/data?page=${page}&limit=10`);
      const result = await response.json();
      data = result.data;
      totalItems = result.total;
    } finally {
      loading = false;
    }
  }
  
  function handlePageChange(page) {
    currentPage = page;
    loadPage(page);
  }
  
  // Load initial data
  onMount(() => loadPage(1));
</script>

{#if loading}
  <div>Loading...</div>
{:else}
  <!-- Display data -->
  {#each data as item}
    <div>{item.name}</div>
  {/each}
{/if}

<Pagination.Root 
  count={totalItems} 
  perPage={10} 
  page={currentPage}
  onPageChange={handlePageChange}
  let:pages 
  let:currentPage
>
  <!-- Pagination UI -->
</Pagination.Root>
```

### URL-based pagination
```svelte
<script>
  import { page } from '$app/stores';
  import { goto } from '$app/navigation';
  
  $: currentPage = parseInt($page.url.searchParams.get('page') || '1');
  
  function handlePageChange(newPage) {
    const url = new URL($page.url);
    url.searchParams.set('page', newPage.toString());
    goto(url.toString(), { replaceState: true });
  }
</script>
```

## Best Practices

- Show page numbers around the current page for easy navigation
- Always include Previous/Next buttons
- Display total item count when helpful
- Consider showing items per page selector for large datasets
- Use URL parameters for bookmarkable pagination
- Show loading states during page transitions

## Accessibility

- Proper ARIA labels for screen readers
- Keyboard navigation support
- Clear indication of current page

## Documentation

- [Official Pagination Documentation](https://www.shadcn-svelte.com/docs/components/pagination)
