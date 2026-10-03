<script>
  let { stones = [] } = $props();
</script>

{#if stones.length}
  <div class="my-3 space-y-2" aria-label="Stones">
    {#each stones as stone (stone.id)}
      <article class="rounded-lg border border-border bg-background/70 p-3">
        {#if stone.withdrawn}
          <p class="text-sm text-muted-foreground">Stone removed</p>
        {:else}
          <a
            href={stone.url}
            target="_blank"
            rel="noopener noreferrer"
            class="font-medium text-primary hover:underline">
            {stone.title}
          </a>
          <p class="mt-1 text-xs text-muted-foreground">Public stone · Revision {stone.number}</p>
          {#if stone.newer_revision_available}
            <a
              href={stone.latest_url}
              target="_blank"
              rel="noopener noreferrer"
              class="mt-1 inline-block text-xs text-primary hover:underline">
              Newer revision available
            </a>
          {/if}
        {/if}
      </article>
    {/each}
  </div>
{/if}
