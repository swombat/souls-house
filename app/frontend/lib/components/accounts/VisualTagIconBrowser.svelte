<script>
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import VisualTagIcon from '$lib/components/chat/VisualTagIcon.svelte';
  import { iconLabel, visualTagColour } from '$lib/visual-tags';
  import { visualTagIconMatches } from '$lib/visual-tag-icon-search';

  let { options = [], value = $bindable('ChatCircle'), colour = 'slate', disabled = false } = $props();
  let query = $state('');
  let limit = $state(120);
  const matches = $derived(options.filter((name) => visualTagIconMatches(name, query)));
  const visible = $derived(matches.slice(0, limit));
  const tabStop = $derived(visible.includes(value) ? value : visible[0]);
  function moveFocus(event) {
    const buttons = [...event.currentTarget.parentElement.querySelectorAll('button')];
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
    limit = 120;
  });
</script>

<section class="flex min-h-0 flex-col gap-3" aria-label="Icon library">
  <Input aria-label="Search icons" type="search" placeholder="Search all icons…" bind:value={query} {disabled} />
  <div class="flex items-center justify-between text-xs text-muted-foreground" aria-live="polite">
    <span>{matches.length.toLocaleString()} icons{query ? ' found' : ' to explore'}</span>
    <span>Selected: {iconLabel(value)}</span>
  </div>
  <div class="min-h-0 flex-1 overflow-y-auto overscroll-contain rounded-xl border bg-muted/20 p-2">
    <div class="grid grid-cols-[repeat(auto-fill,minmax(44px,1fr))] gap-1">
      {#each visible as name (name)}
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
      {:else}
        <p class="col-span-full py-10 text-center text-sm text-muted-foreground">
          No icons match “{query}”. Try another word.
        </p>
      {/each}
    </div>
    {#if matches.length > limit}
      <Button type="button" variant="ghost" class="mt-3 w-full" onclick={() => (limit += 120)}>Show more icons</Button>
    {/if}
  </div>
</section>
