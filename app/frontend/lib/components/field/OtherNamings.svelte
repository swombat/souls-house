<script>
  // Namings of this voice with no usable sample, and why, a page at a time.
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { date } from './voice-sample-format.js';

  let { base, count } = $props();
  let others = $state(null);
  let error = $state('');

  async function loadOthers(page = 1) {
    const url = base;
    error = '';
    try {
      const response = await fetch(`${url}/samples?scope=other&page=${page}`, {
        headers: { Accept: 'application/json' },
      });
      if (!response.ok) throw new Error('These namings could not be loaded. Please try again.');
      const body = await response.json();
      if (url === base) others = body;
    } catch (failure) {
      if (url === base) error = failure.message;
    }
  }
</script>

<div class="text-sm">
  {#if error}<p role="alert" class="text-destructive">{error}</p>{/if}
  {#if !others}
    <button type="button" class="text-muted-foreground underline" onclick={() => loadOthers()}>
      {count} other {count === 1 ? 'naming has' : 'namings have'} no usable sample
    </button>
  {:else}
    <p class="text-muted-foreground mb-1">Namings with no usable sample ({others.total})</p>
    <ul class="divide-y rounded-md border text-xs">
      {#each others.namings as naming (naming.id)}
        <li class="flex items-center gap-2 px-3 py-1.5 min-w-0">
          <a href={naming.source_url} class="truncate font-medium hover:underline"
            >{naming.recording_title || 'Untitled recording'}</a>
          <span class="text-muted-foreground shrink-0">{date(naming.recorded_at)} · {naming.label}</span>
          <span class="ml-auto truncate text-muted-foreground">{naming.reason}</span>
        </li>
      {/each}
    </ul>
    {#if others.pages > 1}
      <div class="mt-1 flex items-center gap-2 text-xs">
        <Button size="sm" variant="ghost" disabled={others.page <= 1} onclick={() => loadOthers(others.page - 1)}
          >Previous</Button>
        <span>Page {others.page} of {others.pages}</span>
        <Button
          size="sm"
          variant="ghost"
          disabled={others.page >= others.pages}
          onclick={() => loadOthers(others.page + 1)}>Next</Button>
      </div>
    {/if}
  {/if}
</div>
