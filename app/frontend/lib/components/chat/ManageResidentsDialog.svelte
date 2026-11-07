<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { Spinner } from 'phosphor-svelte';

  // One list of everyone who could be in this conversation: the residents
  // already seated (ticked) and the ones who could join (unticked), guests
  // from other houses included. Save sends the whole ticked set.
  let { open = $bindable(false), agents = [], addableAgents = [], processing = false, onsave } = $props();

  let selected = $state(new Set());
  let wasOpen = false;

  const seatedIds = $derived(new Set(agents.map((agent) => agent.id)));
  const rows = $derived([
    ...agents.map((agent) => ({ agent, seated: true, locked: !agent.can_remove_from_chat })),
    ...addableAgents
      .filter((agent) => !seatedIds.has(agent.id))
      .map((agent) => ({ agent, seated: false, locked: false })),
  ]);
  const changed = $derived(selected.size !== seatedIds.size || [...selected].some((id) => !seatedIds.has(id)));

  $effect(() => {
    if (open && !wasOpen) selected = new Set(seatedIds);
    wasOpen = open;
  });

  function toggle(id, checked) {
    const next = new Set(selected);
    if (checked) next.add(id);
    else next.delete(id);
    selected = next;
  }

  function save() {
    if (!changed || processing) return;
    onsave?.([...selected]);
  }
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="max-w-md">
    <Dialog.Header>
      <Dialog.Title>Manage residents</Dialog.Title>
      <Dialog.Description>Tick who should be in this conversation.</Dialog.Description>
    </Dialog.Header>

    <ul class="-mx-2 max-h-[min(50vh,24rem)] overflow-y-auto overscroll-contain" data-testid="manage-residents-list">
      {#each rows as row (row.agent.id)}
        <li>
          <label
            class="flex min-h-11 items-center gap-3 rounded-md px-2 py-2 hover:bg-accent {row.locked
              ? 'opacity-60'
              : 'cursor-pointer'}">
            <input
              type="checkbox"
              class="size-4 shrink-0 accent-primary"
              checked={selected.has(row.agent.id)}
              disabled={row.locked || processing}
              onchange={(event) => toggle(row.agent.id, event.currentTarget.checked)} />
            <span class="min-w-0 flex-1 truncate">{row.agent.name}</span>
            {#if row.agent.guest}
              <span class="shrink-0 rounded-full border px-2 py-0.5 text-xs text-muted-foreground">Guest</span>
            {/if}
            {#if row.locked}
              <span class="shrink-0 text-xs text-muted-foreground">can't remove</span>
            {/if}
          </label>
        </li>
      {:else}
        <li class="px-2 py-2 text-sm text-muted-foreground">No residents can join this conversation.</li>
      {/each}
    </ul>

    <p class="text-xs text-muted-foreground">Past messages stay. A responding resident must finish before removal.</p>

    <Dialog.Footer>
      <Button variant="outline" onclick={() => (open = false)}>Cancel</Button>
      <Button onclick={save} disabled={!changed || processing}>
        {#if processing}
          <Spinner size={16} class="mr-2 animate-spin" />
          Saving…
        {:else}
          Save
        {/if}
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
