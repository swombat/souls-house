<script>
  import { agentIconFor } from '$lib/agent-icons';

  let { residents = [] } = $props();
</script>

<span class="inline-flex flex-wrap gap-1.5">
  {#each residents as resident (resident.id)}
    {@const Icon = agentIconFor(resident.icon)}
    <span
      class="inline-flex items-center gap-1 rounded-md border px-2 py-0.5 text-xs
             {resident.colour
        ? `border-${resident.colour}-300 dark:border-${resident.colour}-700 text-${resident.colour}-700 dark:text-${resident.colour}-300`
        : 'border-border text-muted-foreground'}">
      <Icon size={12} weight="duotone" />
      {resident.name}
    </span>
  {/each}
</span>
