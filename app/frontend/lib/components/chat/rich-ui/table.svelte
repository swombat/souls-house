<script>
  import { displayRichValue, richTableRows } from '$lib/rich-ui.js';
  let { element } = $props();
  let filter = $state('');
  let column = $state(null);
  let direction = $state(1);
  let rows = $derived(richTableRows(element.props.rows, filter, column, direction));
  function sort(index) {
    direction = column === index ? -direction : 1;
    column = index;
  }
</script>

<div class="min-w-0 space-y-2">
  <label class="flex flex-wrap items-center gap-2 text-sm">
    <span>Filter {element.props.title || 'table'}</span>
    <input
      type="search"
      bind:value={filter}
      class="min-w-0 rounded border border-input bg-background px-2 py-1 text-foreground" />
  </label>
  <div class="overflow-x-auto rounded border border-border">
    <table class="w-full text-left text-sm">
      <caption class="p-2 text-left font-semibold">{element.props.title || 'Data table'}</caption>
      <thead>
        <tr class="border-b border-border">
          {#each element.props.columns as label, index}
            <th scope="col" aria-sort={column === index ? (direction === 1 ? 'ascending' : 'descending') : 'none'}>
              <button
                type="button"
                class="w-full px-3 py-2 text-left hover:bg-muted focus-visible:outline"
                onclick={() => sort(index)}>
                {label}
                {#if column === index}<span aria-hidden="true">{direction === 1 ? ' ↑' : ' ↓'}</span>{/if}
              </button>
            </th>
          {/each}
        </tr>
      </thead>
      <tbody>
        {#each rows as row}
          <tr class="border-b border-border last:border-0">
            {#each row as cell}
              <td class="max-w-xs whitespace-pre-wrap px-3 py-2 align-top [overflow-wrap:anywhere]"
                >{displayRichValue(cell)}</td>
            {/each}
          </tr>
        {:else}
          <tr><td colspan={element.props.columns.length} class="p-3 text-muted-foreground">No matching rows</td></tr>
        {/each}
      </tbody>
    </table>
  </div>
  <p class="text-xs text-muted-foreground">{rows.length} of {element.props.rows.length} rows</p>
</div>
