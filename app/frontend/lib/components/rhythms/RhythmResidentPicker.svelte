<script>
  import { agentIconFor } from '$lib/agent-icons';

  let { residents = [], selected = $bindable([]) } = $props();

  function toggle(id) {
    selected = selected.includes(id) ? selected.filter((value) => value !== id) : [...selected, id];
  }
</script>

<div class="flex flex-wrap gap-2" role="group" aria-label="Residents">
  {#each residents as resident (resident.id)}
    {@const Icon = agentIconFor(resident.icon)}
    {@const isSelected = selected.includes(resident.id)}
    <button
      type="button"
      aria-pressed={isSelected}
      disabled={resident.unavailable && !isSelected}
      onclick={() => toggle(resident.id)}
      class="inline-flex items-center gap-2 rounded-md border px-3 py-1.5 text-sm transition-colors
             {isSelected
        ? resident.colour
          ? `bg-${resident.colour}-100 dark:bg-${resident.colour}-900 border-${resident.colour}-400 dark:border-${resident.colour}-600 text-${resident.colour}-700 dark:text-${resident.colour}-300`
          : 'bg-primary text-primary-foreground border-primary'
        : resident.colour
          ? `bg-transparent border-${resident.colour}-300 dark:border-${resident.colour}-700 hover:bg-${resident.colour}-50 dark:hover:bg-${resident.colour}-950 text-${resident.colour}-600 dark:text-${resident.colour}-400`
          : 'bg-muted hover:bg-muted/80 text-muted-foreground border-border'}
             {resident.paused === true ? 'opacity-60' : ''}">
      <Icon size={14} weight="duotone" />
      {resident.name}
      {#if resident.unavailable}
        <span class="text-[10px] uppercase tracking-wide text-muted-foreground">Unavailable</span>
      {/if}
      {#if resident.paused === true}
        <span class="text-[10px] uppercase tracking-wide text-muted-foreground">Paused</span>
      {/if}
    </button>
  {:else}
    <p class="text-sm text-muted-foreground">There are no residents in this account yet.</p>
  {/each}
</div>
