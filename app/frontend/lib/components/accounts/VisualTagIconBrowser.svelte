<script>
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import VisualTagIcon from '$lib/components/chat/VisualTagIcon.svelte';
  import { iconLabel, visualTagColour } from '$lib/visual-tags';
  import { visualTagIconMatches, visualTagBrowseGroups, visualTagCategories } from '$lib/visual-tag-icon-search';

  let { options = [], value = $bindable('ChatCircle'), colour = 'slate', disabled = false } = $props();
  let query = $state('');
  let limit = $state(120);
  let category = $state('');
  const matches = $derived(options.filter((name) => visualTagIconMatches(name, query)));
  const groups = $derived(
    query.trim() ? [{ label: 'Search results', icons: matches }] : visualTagBrowseGroups(options, category)
  );
  const ordered = $derived(groups.flatMap((group) => group.icons));
  const visible = $derived(ordered.slice(0, limit));
  const tabStop = $derived(visible.includes(value) ? value : visible[0]);
  function moveFocus(event) {
    const buttons = [...event.currentTarget.parentElement.parentElement.querySelectorAll('button[aria-pressed]')];
    const index = buttons.indexOf(event.currentTarget);
    const columns = getComputedStyle(event.currentTarget.parentElement).gridTemplateColumns.split(' ').length;
    const offsets = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -columns, ArrowDown: columns };
    let next = event.key === 'Home' ? 0 : event.key === 'End' ? buttons.length - 1 : index + offsets[event.key];
    if (!Number.isFinite(next)) return;
    event.preventDefault();
    buttons[Math.max(0, Math.min(buttons.length - 1, next))]?.focus();
  }
  $effect(() => {
    query;
    category;
    limit = 120;
  });
</script>

<section class="flex min-h-0 flex-col gap-3" aria-label="Icon library">
  <Input aria-label="Search icons" type="search" placeholder="Search all icons…" bind:value={query} {disabled} />
  <div class="flex flex-wrap items-center justify-between gap-2 text-xs text-muted-foreground">
    <span aria-live="polite">{ordered.length.toLocaleString()} icons{query ? ' found' : ' to explore'}</span>
    <select
      aria-label="Browse category"
      bind:value={category}
      disabled={disabled || !!query.trim()}
      class="max-w-48 rounded-md border bg-background p-1.5 text-xs capitalize">
      <option value="">All categories</option>
      {#each visualTagCategories as name}<option value={name}>{name}</option>{/each}
    </select>
  </div>
  <div
    class="flex shrink-0 items-center gap-3 rounded-lg border border-primary/30 bg-muted/30 px-3 py-2"
    aria-label={`Current icon: ${iconLabel(value)}`}>
    <VisualTagIcon icon={value} size={26} class={visualTagColour(colour)} />
    <span class="text-xs"><span class="text-muted-foreground">Current icon</span><br />{iconLabel(value)}</span>
  </div>
  <div class="min-h-0 flex-1 overflow-y-auto overscroll-contain rounded-xl border bg-muted/20 p-2">
    {#each groups as group}
      {@const icons = group.icons.filter((name) => visible.includes(name))}
      {#if icons.length}
        <h3 class="px-1 pb-2 pt-3 text-xs font-medium capitalize text-muted-foreground">{group.label}</h3>
        <div class="grid grid-cols-[repeat(auto-fill,minmax(44px,1fr))] gap-1">
          {#each icons as name (name)}
            <button
              type="button"
              aria-label={iconLabel(name)}
              aria-pressed={value === name}
              tabindex={name === tabStop ? 0 : -1}
              onkeydown={moveFocus}
              title={iconLabel(name)}
              {disabled}
              onclick={() => (value = name)}
              class="flex h-11 items-center justify-center rounded-lg transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring {value ===
              name
                ? 'bg-background ring-2 ring-primary'
                : 'hover:bg-muted'} {visualTagColour(colour)}">
              <VisualTagIcon icon={name} size={26} />
            </button>
          {/each}
        </div>
      {/if}
    {/each}
    {#if !ordered.length}<p class="py-10 text-center text-sm text-muted-foreground">
        No icons match “{query}”. Try another word.
      </p>{/if}
    {#if ordered.length > limit}
      <Button type="button" variant="ghost" class="mt-3 w-full" onclick={() => (limit += 120)}>Show more icons</Button>
    {/if}
  </div>
</section>
