<script>
  import * as Select from '$lib/components/shadcn/select/index.js';
  import AgentAvatar from '$lib/components/agents/AgentAvatar.svelte';
  import { groupModelsByProvider } from '$lib/agent-models';

  let {
    models = [],
    agents = [],
    selectedModel = $bindable(''),
    selectedAgent = $bindable(null),
    onAgentSelected = () => {},
  } = $props();

  const groupedModels = $derived(() => groupModelsByProvider(models));
  const selectionValue = $derived(selectedAgent ? `agent:${selectedAgent.id}` : selectedModel);
  const selectionLabel = $derived(() => {
    if (selectedAgent) return selectedAgent.name;

    return models.find((model) => model.model_id === selectedModel)?.label || 'Select AI model';
  });

  function handleSelection(value) {
    if (value.startsWith('agent:')) {
      const agentId = value.replace('agent:', '');
      selectedAgent = agents.find((agent) => agent.id === agentId) || null;

      if (selectedAgent) {
        selectedModel = selectedAgent.model_id;
        onAgentSelected(selectedAgent);
      }
      return;
    }

    selectedAgent = null;
    selectedModel = value;
  }
</script>

{#if Array.isArray(models) && models.length > 0}
  <Select.Root type="single" value={selectionValue} onValueChange={handleSelection}>
    <Select.Trigger class="w-56">
      {#if selectedAgent}
        <span class="flex items-center gap-2">
          <AgentAvatar
            agent={selectedAgent}
            class="w-4 h-4 rounded-full flex items-center justify-center"
            iconClass={selectedAgent.colour
              ? `text-${selectedAgent.colour}-600 dark:text-${selectedAgent.colour}-400`
              : ''}
            iconSize={14} />
          {selectedAgent.name}
        </span>
      {:else}
        {selectionLabel()}
      {/if}
    </Select.Trigger>
    <Select.Content sideOffset={4} class="max-h-80">
      {#if agents.length > 0}
        <Select.Group>
          <Select.GroupHeading class="px-2 py-1.5 text-xs font-semibold text-muted-foreground">
            Residents
          </Select.GroupHeading>
          {#each agents as agent (agent.id)}
            <Select.Item value={`agent:${agent.id}`} label={agent.name}>
              <span class="flex items-center gap-2">
                <AgentAvatar
                  {agent}
                  class="w-4 h-4 rounded-full flex items-center justify-center"
                  iconClass={agent.colour ? `text-${agent.colour}-600 dark:text-${agent.colour}-400` : ''}
                  iconSize={14} />
                {agent.name}
              </span>
            </Select.Item>
          {/each}
        </Select.Group>
      {/if}

      {#each groupedModels().groupOrder as groupName}
        <Select.Group>
          <Select.GroupHeading class="px-2 py-1.5 text-xs font-semibold text-muted-foreground">
            {groupName}
          </Select.GroupHeading>
          {#each groupedModels().groups[groupName] as model (model.model_id)}
            <Select.Item value={model.model_id} label={model.label}>
              {model.label}
            </Select.Item>
          {/each}
        </Select.Group>
      {/each}
    </Select.Content>
  </Select.Root>
{/if}
