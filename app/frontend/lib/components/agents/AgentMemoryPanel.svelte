<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Plus } from 'phosphor-svelte';
  import { filterMemories } from '$lib/agent-memory';
  import AgentMemoryCard from '$lib/components/agents/AgentMemoryCard.svelte';
  import AgentMemoryFilters from '$lib/components/agents/AgentMemoryFilters.svelte';
  import AgentMemorySummary from '$lib/components/agents/AgentMemorySummary.svelte';
  import AgentNewMemoryForm from '$lib/components/agents/AgentNewMemoryForm.svelte';
  import { siteName } from '$lib/branding';

  let { agent, memories = [], locked = false, oncreate, ondelete, onundiscard, ontoggleProtected } = $props();

  let showNewMemoryForm = $state(false);
  let memorySearch = $state('');
  let showCore = $state(true);
  let showJournal = $state(true);
  let showProtected = $state(true);
  let showDiscarded = $state(false);

  let filteredMemories = $derived.by(() => {
    return filterMemories(memories, { search: memorySearch, showCore, showJournal, showProtected, showDiscarded });
  });

  function createMemory(memory) {
    oncreate?.(memory);
    showNewMemoryForm = false;
  }
</script>

<div class="space-y-6">
  <div class="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-3">
    <div>
      <h2 class="text-lg font-semibold">Resident Memory</h2>
      <p class="text-sm text-muted-foreground">
        {locked
          ? `This resident's memory is self-managed in its external runtime. ${$siteName} shows the last synced memory backup read-only.`
          : "Review and manage this resident's memories. Core memories are permanent; journal entries fade after a week."}
      </p>
    </div>
    <div class="flex flex-col sm:flex-row gap-2">
      {#if !showNewMemoryForm}
        <Button type="button" variant="outline" size="sm" disabled={locked} onclick={() => (showNewMemoryForm = true)}>
          <Plus class="size-4 mr-1" />
          Add Memory
        </Button>
      {/if}
    </div>
  </div>

  {#if locked}
    <div class="rounded-lg border bg-muted/40 p-3 text-sm text-muted-foreground">
      To change this agent's memory, edit the hosted filesystem or let the external agent update itself.
    </div>
  {:else if showNewMemoryForm}
    <AgentNewMemoryForm oncreate={createMemory} oncancel={() => (showNewMemoryForm = false)} />
  {/if}

  {#if memories.length === 0 && !showNewMemoryForm}
    <p class="text-sm text-muted-foreground">This resident has no synced memories yet.</p>
  {:else if memories.length > 0}
    <AgentMemoryFilters bind:memorySearch bind:showCore bind:showJournal bind:showProtected bind:showDiscarded />

    {#if filteredMemories.length === 0}
      <p class="text-sm text-muted-foreground py-4">No memories match your filters.</p>
    {:else}
      <AgentMemorySummary
        filteredCount={filteredMemories.length}
        totalCount={memories.length}
        memoryTokenSummary={agent.memory_token_summary} />
    {/if}

    <div class="space-y-3 max-h-[32rem] overflow-y-auto">
      {#each filteredMemories as memory (memory.id)}
        <AgentMemoryCard {memory} {locked} {ondelete} {onundiscard} {ontoggleProtected} />
      {/each}
    </div>
  {/if}
</div>
