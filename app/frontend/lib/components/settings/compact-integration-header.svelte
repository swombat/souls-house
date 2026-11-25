<script>
  import AgentAvatar from '$lib/components/agents/AgentAvatar.svelte';
  import { CaretDown } from 'phosphor-svelte';

  let { title, detail, toggleName = title, residents, warning, icon, open, panelId, onToggle } = $props();

  const maxAvatars = 4;
  let others = $derived(residents.slice(maxAvatars));
  let otherNames = $derived(others.map(({ name }) => name).join(', '));
  let fullTitle = $derived(detail ? `${title} · ${detail}` : title);
  let description = $derived(
    [detail, warning, residents.length ? `Shared with ${residents.map(({ name }) => name).join(', ')}` : null]
      .filter(Boolean)
      .join('. ')
  );
</script>

<h3>
  <button
    type="button"
    class="flex min-h-10 w-full items-center gap-2 rounded-xl px-2 py-1 text-left transition hover:bg-muted/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring sm:px-3"
    aria-expanded={open}
    aria-controls={panelId}
    aria-label={`${open ? 'Hide' : 'Show'} details for ${toggleName}`}
    aria-describedby={description ? `${panelId}-summary` : undefined}
    onclick={onToggle}>
    {@render icon()}
    <span class="min-w-0 flex-1 truncate text-sm" title={fullTitle}>
      <span class="font-semibold">{title}</span>
      {#if detail}<span class="text-muted-foreground"> · {detail}</span>{/if}
    </span>
    {#if warning}
      <span
        role="img"
        aria-label={warning}
        title={warning}
        data-testid="compact-integration-warning"
        class="size-2 shrink-0 rounded-full bg-amber-600 dark:bg-amber-400"></span>
    {/if}
    {#if residents.length > 0}
      <span class="flex shrink-0 items-center gap-0.5" aria-hidden="true">
        {#each residents.slice(0, maxAvatars) as resident (resident.id)}
          <AgentAvatar
            agent={resident}
            class="flex size-5 items-center justify-center rounded-full"
            fallbackClass={resident.colour ? `bg-${resident.colour}-100 dark:bg-${resident.colour}-900` : 'bg-muted'}
            iconClass={resident.colour
              ? `text-${resident.colour}-700 dark:text-${resident.colour}-300`
              : 'text-muted-foreground'}
            iconSize={12} />
        {/each}
        {#if others.length > 0}
          <span class="rounded-full bg-muted px-1 text-xs text-muted-foreground" title={otherNames}
            >+{others.length}</span>
        {/if}
      </span>
    {/if}
    {#if description}<span id={`${panelId}-summary`} class="sr-only">{description}</span>{/if}
    <CaretDown size={14} class={`shrink-0 text-muted-foreground transition-transform ${open ? 'rotate-180' : ''}`} />
  </button>
</h3>
