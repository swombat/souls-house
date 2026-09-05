<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input';
  import { Label } from '$lib/components/shadcn/label';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { findModelLabel } from '$lib/agent-models';
  import AgentModelSelect from '$lib/components/agents/AgentModelSelect.svelte';

  let {
    open = $bindable(false),
    agent = null,
    groupedModels = {},
    predecessorName = $bindable(''),
    targetModel = $bindable('openrouter/auto'),
    processing = false,
    onsubmit,
  } = $props();
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="max-w-lg">
    <Dialog.Header>
      <Dialog.Title>Upgrade {agent?.name ?? 'Resident'}</Dialog.Title>
      <Dialog.Description>
        {agent?.name ?? 'This agent'} keeps its identity, conversations, and telegram bot — only the model changes. A historical
        predecessor record preserves the current model and copied memories. It has no harness, is marked deprecated/unavailable,
        and cannot participate in conversations. No runtime or credentials are cloned.
      </Dialog.Description>
    </Dialog.Header>

    <form
      onsubmit={(event) => {
        event.preventDefault();
        onsubmit?.();
      }}
      class="space-y-4 mt-4">
      <div class="space-y-2">
        <Label>Currently running</Label>
        <p class="text-sm font-medium px-3 py-2 bg-muted rounded-md">
          {findModelLabel(groupedModels, agent?.model_id ?? '')}
        </p>
      </div>

      <div class="space-y-2">
        <Label>Upgrade to</Label>
        <AgentModelSelect {groupedModels} bind:value={targetModel} triggerClass="w-full" contentClass="max-h-60" />
      </div>

      <div class="space-y-2">
        <Label for="predecessor_name">Predecessor name</Label>
        <Input id="predecessor_name" type="text" bind:value={predecessorName} required maxlength={100} />
        <p class="text-xs text-muted-foreground">
          The preserved past-self carrying the current model and memories. Naming it after the old model (e.g. <em
            >"{agent?.name ?? 'Agent'} (Claude Opus 4.6)"</em
          >) keeps the lineage readable.
        </p>
      </div>

      <Dialog.Footer>
        <Button type="button" variant="outline" onclick={() => (open = false)}>Cancel</Button>
        <Button type="submit" disabled={processing}>
          {processing ? 'Upgrading...' : 'Upgrade & preserve past-self'}
        </Button>
      </Dialog.Footer>
    </form>
  </Dialog.Content>
</Dialog.Root>
