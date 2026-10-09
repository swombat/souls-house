<script>
  // Field search results: dated, tagged, with excerpts. Choosing one opens the
  // item beside the list, like any other item.
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import SearchExcerpt from '$lib/components/field/SearchExcerpt.svelte';
  import { formatWhen } from '$lib/field';
  import { File, Microphone, Notepad } from 'phosphor-svelte';

  let { search, query = '', filterTags = [], currentKey = null, onSelect, onMore } = $props();

  const kindLabel = { file: 'File', note: 'Note', recording: 'Recording' };
</script>

{#if search.error}
  <p class="text-sm text-destructive p-4" role="alert">{search.error}</p>
{:else if search.results.length === 0}
  <p class="text-sm text-muted-foreground p-4" data-testid="field-search-empty">
    Nothing matched “{query}”{filterTags.length ? ` with ${filterTags.join(', ')}` : ''}. Every word has to appear; try
    fewer words or one distinctive name. Recordings are searchable once their transcript is ready.
  </p>
{/if}
{#each search.results as result (result.key)}
  <button onclick={() => onSelect(result.key)} class="w-full text-left" data-testid="field-search-result">
    <Card.Root
      class="hover:border-primary/50 transition-colors {currentKey === result.key
        ? 'border-primary ring-1 ring-primary'
        : ''}">
      <Card.Content class="p-4 space-y-2">
        <div class="flex items-start gap-3">
          {#if result.kind === 'file'}
            <File class="size-5 text-muted-foreground shrink-0 mt-0.5" weight="duotone" />
          {:else if result.kind === 'recording'}
            <Microphone class="size-5 text-muted-foreground shrink-0 mt-0.5" weight="duotone" />
          {:else}
            <Notepad class="size-5 text-muted-foreground shrink-0 mt-0.5" weight="duotone" />
          {/if}
          <div class="flex-1 min-w-0">
            <h3 class="font-semibold truncate">{result.title}</h3>
            <p class="text-xs text-muted-foreground">
              {kindLabel[result.kind]} · {formatWhen(result.date)}
              {#if result.tags.length}· {result.tags.join(', ')}{/if}
            </p>
          </div>
        </div>
        {#each result.excerpts as excerpt, index (index)}
          <SearchExcerpt {excerpt} />
        {/each}
      </Card.Content>
    </Card.Root>
  </button>
{/each}
{#if search.next_page != null}
  <Button variant="outline" class="w-full" onclick={onMore}>More results</Button>
{/if}
