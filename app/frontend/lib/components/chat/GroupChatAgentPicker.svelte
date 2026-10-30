<script>
  import { agentIconFor } from '$lib/agent-icons';
  import AgentUsageName from '$lib/components/chat/AgentUsageName.svelte';
  import { sortAgentsByAvailability, watchAgentsRemaining } from '$lib/agent-subscription-usage';

  let { agents = [], accountId, showUsage = false, selectedAgentIds = $bindable([]) } = $props();
  let remainingById = $state({});
  // Collapsed to one line by default; Change opens the full picker.
  let expanded = $state(false);
  const selectedAgents = $derived(agents.filter((agent) => selectedAgentIds.includes(agent.id)));
  const available = $derived(agents.filter((agent) => agent.paused !== true));
  const allSelected = $derived(
    available.length > 0 && available.every((agent) => selectedAgentIds.includes(agent.id))
  );
  const summary = $derived.by(() => {
    if (allSelected && selectedAgents.length > 1) return `All ${selectedAgents.length} residents`;
    const names = selectedAgents.map((agent) => agent.name);
    if (names.length <= 1) return names[0] || '';
    return `${names.slice(0, -1).join(', ')} and ${names.at(-1)}`;
  });
  const open = $derived(expanded || selectedAgentIds.length === 0);
  let sortedAgents = $derived(sortAgentsByAvailability(agents, remainingById));

  $effect(() =>
    watchAgentsRemaining(accountId, agents, (id, value) => {
      if (remainingById[id] !== value) remainingById = { ...remainingById, [id]: value };
    })
  );

  function toggleAgent(agentId) {
    if (selectedAgentIds.includes(agentId)) {
      selectedAgentIds = selectedAgentIds.filter((id) => id !== agentId);
      return;
    }

    selectedAgentIds = [...selectedAgentIds, agentId];
  }
</script>

{#if agents.length > 0 && !open}
  <div class="border-b border-border px-4 md:px-6 py-2 bg-muted/5 flex items-center gap-2 min-w-0">
    <div class="flex items-center -space-x-1 shrink-0" aria-hidden="true">
      {#each selectedAgents.slice(0, 7) as agent (agent.id)}
        {@const IconComponent = agentIconFor(agent.icon)}
        <span
          class="w-6 h-6 rounded-full flex items-center justify-center border border-background {agent.colour
            ? `bg-${agent.colour}-100 dark:bg-${agent.colour}-900`
            : 'bg-muted'}"
          title={agent.name}>
          <IconComponent
            size={12}
            weight="duotone"
            class={agent.colour ? `text-${agent.colour}-600 dark:text-${agent.colour}-400` : 'text-muted-foreground'} />
        </span>
      {/each}
    </div>
    <span class="text-sm truncate" data-testid="participant-summary">{summary}</span>
    <button
      type="button"
      class="ml-auto shrink-0 text-sm text-primary underline-offset-2 hover:underline"
      aria-expanded="false"
      onclick={() => (expanded = true)}>
      Change
    </button>
  </div>
{:else if agents.length > 0}
  <div class="border-b border-border px-4 md:px-6 py-3 bg-muted/5">
    <div class="flex items-center mb-2">
      <div class="text-sm font-medium">Select residents to participate:</div>
      {#if selectedAgentIds.length > 0}
        <button
          type="button"
          class="ml-auto text-sm text-primary underline-offset-2 hover:underline"
          aria-expanded="true"
          onclick={() => (expanded = false)}>
          Done
        </button>
      {/if}
    </div>
    <div class="flex flex-wrap gap-2">
      {#each sortedAgents as agent (agent.id)}
        {@const IconComponent = agentIconFor(agent.icon)}
        {@const isSelected = selectedAgentIds.includes(agent.id)}
        <button
          type="button"
          aria-pressed={isSelected}
          onclick={() => toggleAgent(agent.id)}
          class="inline-flex items-center gap-2 px-3 py-1.5 rounded-md text-sm border transition-colors
                 {isSelected
            ? agent.colour
              ? `bg-${agent.colour}-100 dark:bg-${agent.colour}-900 border-${agent.colour}-400 dark:border-${agent.colour}-600 text-${agent.colour}-700 dark:text-${agent.colour}-300`
              : 'bg-primary text-primary-foreground border-primary'
            : agent.colour
              ? `bg-transparent border-${agent.colour}-300 dark:border-${agent.colour}-700 hover:bg-${agent.colour}-50 dark:hover:bg-${agent.colour}-950 text-${agent.colour}-600 dark:text-${agent.colour}-400`
              : 'bg-muted hover:bg-muted/80 text-muted-foreground border-border'}
                 {agent.paused === true ? 'opacity-60' : ''}">
          <IconComponent
            size={14}
            weight="duotone"
            class={agent.colour && !isSelected ? `text-${agent.colour}-600 dark:text-${agent.colour}-400` : ''} />
          <AgentUsageName {accountId} {agent} {showUsage} />
          {#if agent.paused === true}
            <span class="text-[10px] uppercase tracking-wide text-muted-foreground">Paused</span>
          {/if}
        </button>
      {/each}
    </div>
    {#if selectedAgentIds.length === 0}
      <p class="text-xs text-amber-600 mt-2">Select at least one resident to start a group chat</p>
    {/if}
  </div>
{/if}
