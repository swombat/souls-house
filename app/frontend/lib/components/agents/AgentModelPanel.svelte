<script>
  import { Label } from '$lib/components/shadcn/label';
  import * as Select from '$lib/components/shadcn/select/index.js';
  import { findModel } from '$lib/agent-models';
  import AgentModelSelect from '$lib/components/agents/AgentModelSelect.svelte';
  import { siteName } from '$lib/branding';

  let { form, groupedModels = {}, selectedModel = $bindable(), runtimeManaged = false } = $props();

  let reasoning = $derived(findModel(groupedModels, selectedModel)?.reasoning || null);
  let effortOptions = $derived(
    reasoning
      ? [
          {
            value: 'default',
            label: `Provider default (${reasoning.options.find((option) => option.value === reasoning.default)?.label || reasoning.default})`,
            description: 'Use the default reasoning setting advertised for this model.',
          },
          ...reasoning.options,
        ]
      : []
  );

  let selectedEffort = $derived(
    effortOptions.find((option) => option.value === $form.agent.reasoning_effort) || effortOptions[0]
  );

  $effect(() => {
    if (!reasoning || !effortOptions.some((option) => option.value === $form.agent.reasoning_effort)) {
      $form.agent.reasoning_effort = 'default';
    }
  });
</script>

<div class="space-y-8">
  <div class="space-y-4">
    <div>
      <h2 class="text-lg font-semibold">AI Model</h2>
      <p class="text-sm text-muted-foreground">
        {runtimeManaged
          ? `Choose the model ${$siteName} sends to the external runtime on each trigger.`
          : 'Choose which AI model powers this agent'}
      </p>
    </div>
    <AgentModelSelect {groupedModels} bind:value={selectedModel} />
  </div>

  {#if reasoning}
    <div class="space-y-4">
      <div>
        <h2 class="text-lg font-semibold">{reasoning.label}</h2>
        <p class="text-sm text-muted-foreground">
          Choose from the reasoning settings this model exposes through Chaos.
        </p>
      </div>
      <div class="space-y-2">
        <Label for="reasoning_effort">{reasoning.label}</Label>
        <Select.Root
          type="single"
          value={$form.agent.reasoning_effort}
          onValueChange={(value) => ($form.agent.reasoning_effort = value)}>
          <Select.Trigger id="reasoning_effort" class="w-full max-w-xs">{selectedEffort.label}</Select.Trigger>
          <Select.Content sideOffset={4}>
            {#each effortOptions as option}
              <Select.Item value={option.value} label={option.label}>{option.label}</Select.Item>
            {/each}
          </Select.Content>
        </Select.Root>
        <p class="text-xs text-muted-foreground">{selectedEffort.description}</p>
      </div>
    </div>
  {:else}
    <div class="space-y-1">
      <h2 class="text-lg font-semibold">Reasoning</h2>
      <p class="text-sm text-muted-foreground">
        This model does not expose a configurable reasoning setting. Chaos will use the model's default behavior.
      </p>
    </div>
  {/if}
</div>
