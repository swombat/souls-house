<script>
  // The model a resident will use for its next turn in this conversation,
  // next to its Ask button. While a turn runs, what is running now and what
  // is selected next are shown as two facts: the running turn is never
  // relabelled.
  import * as DropdownMenu from '$lib/components/shadcn/dropdown-menu/index.js';
  import { CaretDown, Spinner, Warning } from 'phosphor-svelte';

  let { agent, selection, running = false, runningLabel = null, saving = false, onselect } = $props();

  const DEFAULT_VALUE = 'default';

  const nextLabel = $derived(selection.label || selection.model_id);
  // A seat pinned to the default model by name differs from one following
  // the default; seat_model_id says which (null means following).
  const currentValue = $derived(
    selection.seat_model_id ?? (selection.selected_by_conversation ? selection.model_id : DEFAULT_VALUE)
  );
  const triggerText = $derived(running ? `Next: ${nextLabel}` : nextLabel);
  const effortText = $derived(
    selection.reasoning_effort && selection.reasoning_effort !== 'default'
      ? `Reasoning effort: ${selection.reasoning_effort}${selection.selected_by_conversation ? ` (${nextLabel}'s default)` : ''}`
      : null
  );

  const triggerTitle = $derived.by(() => {
    if (selection.problem) return `${selection.problem}. Choose another model or use ${agent.name}'s default.`;
    if (running) {
      const now = runningLabel ? `Running now on ${runningLabel}` : 'Running now';
      return `${now}; ${nextLabel} selected for the next turn`;
    }
    if (selection.selected_by_conversation) {
      return `${nextLabel} selected in this conversation. ${agent.name}'s default is ${selection.default_label}.`;
    }
    return `${agent.name} uses its default, ${selection.default_label}. Choose a model for this conversation.`;
  });

  function choose(value) {
    // The server treats a repeat selection as a no-op, so don't second-guess
    // it here: this browser's idea of the current value may be stale.
    if (saving) return;
    onselect?.(value);
  }
</script>

<DropdownMenu.Root>
  <DropdownMenu.Trigger
    disabled={saving}
    aria-label={`Model for ${agent.name}: ${triggerTitle}`}
    title={triggerTitle}
    class="inline-flex h-8 max-w-[10rem] md:max-w-[14rem] items-center gap-1 rounded-r-md border border-l-0 px-2 text-xs
           shadow-xs outline-none transition-colors focus-visible:ring-2 focus-visible:ring-ring disabled:opacity-50
           {selection.problem
      ? 'border-amber-500 bg-amber-50 text-amber-800 hover:bg-amber-100 dark:bg-amber-950/40 dark:text-amber-300'
      : 'border-input bg-background text-muted-foreground hover:bg-accent hover:text-accent-foreground'}">
    {#if saving}
      <Spinner size={12} class="animate-spin shrink-0" />
    {:else if selection.problem}
      <Warning size={12} weight="bold" class="shrink-0" />
    {/if}
    <span class="truncate">{triggerText}</span>
    <CaretDown size={10} class="shrink-0 opacity-60" />
  </DropdownMenu.Trigger>
  <DropdownMenu.Content align="start" class="w-72 max-w-[calc(100vw-2rem)]">
    <DropdownMenu.Label class="text-xs font-normal text-muted-foreground">
      {agent.name}'s model in this conversation
    </DropdownMenu.Label>
    {#if effortText && !selection.problem}
      <p class="px-2 pb-1.5 text-xs text-muted-foreground" data-testid="model-effort">{effortText}</p>
    {/if}
    {#if running}
      <p class="px-2 pb-1.5 text-xs text-muted-foreground">
        {runningLabel ? `Running now on ${runningLabel}.` : 'A turn is running now.'} A change applies from the next turn.
      </p>
    {/if}
    {#if selection.problem}
      <p
        class="mx-2 mb-1.5 rounded bg-amber-50 px-2 py-1 text-xs text-amber-800 dark:bg-amber-950/40 dark:text-amber-300">
        {selection.problem}.
      </p>
    {/if}
    <DropdownMenu.Separator />
    <DropdownMenu.RadioGroup value={currentValue} onValueChange={choose}>
      <DropdownMenu.RadioItem value={DEFAULT_VALUE} class="text-sm">
        Use resident default ({selection.default_label})
      </DropdownMenu.RadioItem>
      <DropdownMenu.Separator />
      {#each selection.choices as choice (choice.model_id)}
        <DropdownMenu.RadioItem value={choice.model_id} class="text-sm">{choice.label}</DropdownMenu.RadioItem>
      {/each}
    </DropdownMenu.RadioGroup>
  </DropdownMenu.Content>
</DropdownMenu.Root>
