<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Robot, Spinner } from 'phosphor-svelte';
  import * as Select from '$lib/components/shadcn/select/index.js';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';

  let {
    open = $bindable(false),
    agents = [],
    title = 'Select Resident',
    description = '',
    confirmLabel = 'Confirm',
    confirmingLabel = 'Confirming...',
    processing = false,
    onconfirm,
  } = $props();

  let selectedAgentId = $state(null);

  function handleConfirm() {
    if (!selectedAgentId) return;
    onconfirm?.(selectedAgentId);
  }

  $effect(() => {
    if (!open) selectedAgentId = null;
  });
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="max-w-md">
    <Dialog.Header>
      <Dialog.Title>{title}</Dialog.Title>
      {#if description}
        <Dialog.Description>{description}</Dialog.Description>
      {/if}
    </Dialog.Header>

    <div class="py-4">
      <Select.Root type="single" value={selectedAgentId} onValueChange={(value) => (selectedAgentId = value)}>
        <Select.Trigger class="w-full">
          {#if selectedAgentId}
            {agents.find((a) => a.id === selectedAgentId)?.name ?? 'Select a resident'}
          {:else}
            Select a resident
          {/if}
        </Select.Trigger>
        <Select.Content sideOffset={4} class="max-h-60">
          {#each agents as agent (agent.id)}
            <Select.Item value={agent.id} label={agent.name}>
              <span class="flex items-center gap-2">
                <Robot size={14} weight="duotone" />
                {agent.name}
              </span>
            </Select.Item>
          {/each}
        </Select.Content>
      </Select.Root>
    </div>

    <Dialog.Footer>
      <Button variant="outline" onclick={() => (open = false)}>Cancel</Button>
      <Button onclick={handleConfirm} disabled={!selectedAgentId || processing}>
        {#if processing}
          <Spinner size={16} class="mr-2 animate-spin" />
          {confirmingLabel}
        {:else}
          {confirmLabel}
        {/if}
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
