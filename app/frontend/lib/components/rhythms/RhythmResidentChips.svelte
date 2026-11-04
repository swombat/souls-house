<script>
  import AgentAvatar from '$lib/components/agents/AgentAvatar.svelte';

  let { residents = [] } = $props();
</script>

<span class="inline-flex flex-wrap gap-1.5">
  {#each residents as resident (resident.id)}
    <span
      class="inline-flex items-center gap-1 rounded-md border px-2 py-0.5 text-xs
             {resident.colour
        ? `border-${resident.colour}-300 dark:border-${resident.colour}-700 text-${resident.colour}-700 dark:text-${resident.colour}-300`
        : 'border-border text-muted-foreground'}">
      <AgentAvatar agent={resident} class="w-3 h-3 rounded-full flex items-center justify-center" iconSize={12} />
      {resident.name}
      {#if resident.model_selected}<span class="opacity-70">· {resident.model_label}</span>{/if}
    </span>
  {/each}
</span>
