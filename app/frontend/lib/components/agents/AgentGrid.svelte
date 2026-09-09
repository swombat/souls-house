<script>
  import AgentCard from '$lib/components/agents/AgentCard.svelte';

  let { agents = [], accountId, onUpgrade, onDisable } = $props();
</script>

<div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
  {#each agents as agent (agent.id)}
    <AgentCard {agent} {accountId} onupgrade={onUpgrade} ondisable={onDisable} />
  {/each}
</div>
