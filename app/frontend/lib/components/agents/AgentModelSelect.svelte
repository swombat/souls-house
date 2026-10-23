<script>
  import * as Popover from '$lib/components/shadcn/popover/index.js';
  import ChevronDownIcon from '@lucide/svelte/icons/chevron-down';
  import CheckIcon from '@lucide/svelte/icons/check';
  import { MagnifyingGlass } from 'phosphor-svelte';
  import { cn } from '$lib/utils.js';
  import { filterGroupedModels, findModelLabel } from '$lib/agent-models';

  // A model picker with a search box, in the manner of the speaker picker:
  // type to narrow the list, arrows to move, Enter to choose.
  let {
    groupedModels = {},
    value = $bindable(),
    triggerClass = 'w-full max-w-md',
    contentClass = 'max-h-80',
    disabled = false,
  } = $props();

  let open = $state(false);
  let query = $state('');
  let activeIndex = $state(0);
  let listEl = $state(null);
  const listId = `model-options-${Math.random().toString(36).slice(2, 9)}`;

  const shownGroups = $derived(Object.entries(filterGroupedModels(groupedModels, query)));
  const shownModels = $derived(shownGroups.flatMap(([, models]) => models));

  $effect(() => {
    if (open) {
      const current = shownModels.findIndex((model) => model.model_id === value);
      activeIndex = !query.trim() && current >= 0 ? current : 0;
    } else {
      query = '';
    }
  });

  $effect(() => {
    if (!open || !listEl) return;
    const active = listEl.querySelector(`[data-index="${activeIndex}"]`);
    active?.scrollIntoView({ block: 'nearest' });
  });

  function choose(model) {
    if (disabled || !model) return;
    value = model.model_id;
    open = false;
  }

  function onKeydown(event) {
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      if (shownModels.length) activeIndex = (activeIndex + 1) % shownModels.length;
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      if (shownModels.length) activeIndex = (activeIndex - 1 + shownModels.length) % shownModels.length;
    } else if (event.key === 'Enter') {
      event.preventDefault();
      choose(shownModels[activeIndex]);
    }
  }

  const indexOf = (model) => shownModels.indexOf(model);
</script>

<Popover.Root bind:open>
  <Popover.Trigger
    {disabled}
    aria-haspopup="listbox"
    class={cn(
      'border-input focus-visible:border-ring focus-visible:ring-ring/50 dark:bg-input/30 dark:hover:bg-input/50 shadow-xs flex h-9 select-none items-center justify-between gap-2 whitespace-nowrap rounded-md border bg-transparent px-3 py-2 text-sm outline-none transition-[color,box-shadow] focus-visible:ring-[3px] disabled:cursor-not-allowed disabled:opacity-50',
      triggerClass
    )}>
    <span class="truncate">{findModelLabel(groupedModels, value)}</span>
    <ChevronDownIcon class="size-4 shrink-0 text-muted-foreground opacity-50" aria-hidden="true" />
  </Popover.Trigger>
  <Popover.Content class="w-(--bits-popover-anchor-width) min-w-64 p-1" align="start">
    <div class="relative pb-1">
      <MagnifyingGlass
        size={14}
        class="pointer-events-none absolute left-2 top-2 text-muted-foreground"
        aria-hidden="true" />
      <input
        type="search"
        bind:value={query}
        onkeydown={onKeydown}
        placeholder="Find a model…"
        aria-label="Find a model"
        role="combobox"
        aria-expanded="true"
        aria-controls={listId}
        aria-activedescendant={shownModels[activeIndex] ? `${listId}-${activeIndex}` : undefined}
        autocomplete="off"
        class="h-8 w-full rounded-md bg-muted/60 pl-7 pr-2 text-sm outline-none focus-visible:ring-1 focus-visible:ring-ring"
        data-testid="model-filter" />
    </div>
    <div bind:this={listEl} id={listId} role="listbox" class={cn('overflow-y-auto', contentClass)}>
      {#each shownGroups as [groupName, models] (groupName)}
        <div role="group" aria-label={groupName}>
          <div class="px-2 py-1.5 text-xs font-semibold text-muted-foreground" aria-hidden="true">{groupName}</div>
          {#each models as model (model.model_id)}
            {@const index = indexOf(model)}
            <div
              id={`${listId}-${index}`}
              data-index={index}
              role="option"
              tabindex="-1"
              aria-selected={model.model_id === value}
              class={cn(
                'relative flex w-full cursor-default select-none items-center gap-2 rounded-sm py-1.5 pl-2 pr-8 text-sm',
                index === activeIndex && 'bg-accent text-accent-foreground'
              )}
              onmousemove={() => (activeIndex = index)}
              onclick={() => choose(model)}
              onkeydown={(event) => event.key === 'Enter' && choose(model)}>
              {model.label}
              {#if model.model_id === value}
                <CheckIcon class="absolute right-2 size-4" aria-hidden="true" />
              {/if}
            </div>
          {/each}
        </div>
      {:else}
        <p class="px-2 py-1.5 text-sm text-muted-foreground" data-testid="model-filter-empty">
          No model matches “{query.trim()}”.
        </p>
      {/each}
    </div>
  </Popover.Content>
</Popover.Root>
