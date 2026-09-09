<script>
  import AgentCard from '$lib/components/agents/AgentCard.svelte';

  let { agents = [], accountId, onUpgrade, onDisable, showActions = true, admin = false } = $props();
  let showDisabled = $state(false);
  let active = $derived(agents.filter((agent) => agent.active && !agent.deprecated));
  let disabled = $derived(agents.filter((agent) => !agent.active && !agent.deprecated));
  let deprecated = $derived(agents.filter((agent) => agent.deprecated));
</script>

{#snippet cards(residents)}
  <div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
    {#each residents as agent (agent.id)}
      <AgentCard {agent} {accountId} {showActions} {admin} onupgrade={onUpgrade} ondisable={onDisable} />
    {/each}
  </div>
{/snippet}

{@render cards(active)}
{#if disabled.length || deprecated.length}
  <label class="mt-4 flex items-center gap-2 text-sm text-muted-foreground cursor-pointer">
    <input type="checkbox" bind:checked={showDisabled} class="accent-primary" />
    Show disabled
  </label>
  {#if showDisabled}
    <div class="mt-4 space-y-4">
      {#if disabled.length}{@render cards(disabled)}{/if}
      {#if deprecated.length}
        <hr />
        {@render cards(deprecated)}
      {/if}
    </div>
  {/if}
{/if}
