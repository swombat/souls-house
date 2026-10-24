<script>
  import {
    Pagination,
    PaginationContent,
    PaginationItem,
    PaginationLink,
    PaginationPrevButton,
    PaginationNextButton,
    PaginationEllipsis,
  } from '$lib/components/shadcn/pagination/index.js';

  let { pagination = {}, currentPage = $bindable(1), onPageChange = () => {}, class: className = '' } = $props();

  // Update currentPage when pagination changes from server
  $effect(() => {
    currentPage = pagination.page || 1;
  });

  function handlePageChange(newPage) {
    // If newPage is an object with a value property, extract it
    const pageNum = typeof newPage === 'object' ? newPage.value : newPage;
    if (pageNum && pageNum !== pagination.page) {
      onPageChange(pageNum);
    }
  }
</script>

{#if pagination.last > 1}
  <div class="flex flex-wrap justify-between items-center gap-x-4 gap-y-2 p-4 border-t {className}">
    <span class="text-sm text-base-content/60 whitespace-nowrap">
      Showing {pagination.from || 0} to {pagination.to || 0} of {pagination.count} entries
    </span>
    <Pagination
      bind:page={currentPage}
      count={pagination.count}
      perPage={pagination.per_page || 20}
      onPageChange={handlePageChange}>
      <PaginationContent>
        <PaginationItem>
          <PaginationPrevButton disabled={pagination.page <= 1} />
        </PaginationItem>

        {#each pagination.series || [] as item}
          {#if item === 'gap'}
            <PaginationItem>
              <PaginationEllipsis />
            </PaginationItem>
          {:else}
            <PaginationItem>
              <PaginationLink page={{ value: item }} isActive={item == pagination.page}>
                {item}
              </PaginationLink>
            </PaginationItem>
          {/if}
        {/each}

        <PaginationItem>
          <PaginationNextButton disabled={pagination.page >= pagination.last} />
        </PaginationItem>
      </PaginationContent>
    </Pagination>
  </div>
{/if}
