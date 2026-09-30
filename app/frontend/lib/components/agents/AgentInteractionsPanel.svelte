<script>
  import InteractionCard from './interaction-card.svelte';
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button';

  let { interactions = [], pagination = {}, account, agent, runtimeObservabilityUrl = null } = $props();

  const tokenColumns = [
    ['uncached_input_tokens', 'Ordinary'],
    ['cache_creation_input_tokens', 'Write'],
    ['cache_read_input_tokens', 'Read'],
    ['output_tokens', 'Output'],
    ['reasoning_output_tokens', 'Reasoning'],
  ];

  function goToPage(page) {
    router.get(
      `/accounts/${account.id}/agents/${agent.id}/edit`,
      { tab: 'interactions', page },
      {
        preserveScroll: true,
        preserveState: false,
      }
    );
  }
</script>

<div class="space-y-5">
  <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
    <div>
      <h2 class="text-xl font-semibold">Sessions</h2>
      <p class="text-sm text-muted-foreground">
        Resident runtime sessions in reverse chronological order. Token values are shown only when the runtime reported
        trigger-local instrumentation. Costs are estimates using public API prices as of 22 July 2026.
      </p>
      <p class="mt-1 text-xs text-muted-foreground">
        Diagnostic stdout and stderr are stored per trigger. The runtime currently retains only the final 4,000
        characters of each stream; a 4,000-character value may therefore be truncated.
      </p>
    </div>
    {#if runtimeObservabilityUrl}
      <a href={runtimeObservabilityUrl}>
        <Button type="button" variant="outline" size="sm">Detailed runtime usage</Button>
      </a>
    {/if}
  </div>

  {#if interactions.length === 0}
    <div class="rounded border p-8 text-center text-sm text-muted-foreground">No runtime sessions recorded yet.</div>
  {:else}
    <div class="space-y-3">
      {#each interactions as interaction}
        <InteractionCard {interaction} {account} {tokenColumns} />
      {/each}
    </div>
  {/if}

  {#if pagination.pages > 1}
    <div class="flex items-center justify-between gap-3 border-t pt-4">
      <p class="text-sm text-muted-foreground">
        {pagination.from}–{pagination.to} of {pagination.count}
      </p>
      <div class="flex gap-2">
        <Button
          type="button"
          variant="outline"
          size="sm"
          disabled={!pagination.prev}
          onclick={() => goToPage(pagination.prev)}>
          Previous
        </Button>
        <Button
          type="button"
          variant="outline"
          size="sm"
          disabled={!pagination.next}
          onclick={() => goToPage(pagination.next)}>
          Next
        </Button>
      </div>
    </div>
  {/if}
</div>
