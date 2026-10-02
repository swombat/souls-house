<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Spinner, UsersThree } from 'phosphor-svelte';
  import { accountChatAgentTriggerPath, editAccountAgentPath } from '@/routes';
  import { agentIconFor } from '$lib/agent-icons';
  import AgentUsageName from '$lib/components/chat/AgentUsageName.svelte';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { onDestroy } from 'svelte';

  let {
    agents = [],
    accountId,
    chatId,
    showUsage = false,
    disabled = false,
    activeRuntimeAgentIds = [],
    responseMarker = null,
    onTrigger = null,
  } = $props();
  let triggeringAgent = $state(null);
  let triggeringAll = $state(false);
  let waitingForResponse = $state(false);
  let responseMarkerAtTrigger = $state(null);
  let timeoutId = null;
  let errorOpen = $state(false);
  let triggerError = $state('');
  let missingCredentials = $state([]);

  async function submitTrigger(body) {
    try {
      const response = await fetch(accountChatAgentTriggerPath(accountId, chatId), {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          Accept: 'application/json',
          'Content-Type': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
        },
        body: JSON.stringify(body),
      });
      if (!response.ok) {
        const data = await response.json().catch(() => ({}));
        missingCredentials = data.code === 'missing_credentials' ? data.agents || [] : [];
        throw new Error(data.error || 'Could not ask the resident. Please try again.');
      }
      onTrigger?.();
    } catch (error) {
      clearWaitingState();
      triggerError = error.message;
      errorOpen = true;
    }
  }

  function clearWaitingState() {
    waitingForResponse = false;
    triggeringAgent = null;
    triggeringAll = false;
    responseMarkerAtTrigger = null;
    if (timeoutId) {
      clearTimeout(timeoutId);
      timeoutId = null;
    }
  }

  function beginWaiting() {
    waitingForResponse = true;
    responseMarkerAtTrigger = responseMarker;
    if (timeoutId) clearTimeout(timeoutId);
    timeoutId = setTimeout(() => {
      clearWaitingState();
    }, 120_000);
  }

  // When disabled becomes true (streaming started), clear our waiting state
  $effect(() => {
    if (disabled && waitingForResponse) {
      clearWaitingState();
    }
  });

  // External agents post a completed assistant message rather than a streaming
  // placeholder. Clear the local trigger spinner when the chat receives a new
  // assistant message marker from ActionCable/Inertia reload.
  $effect(() => {
    if (waitingForResponse && responseMarker && responseMarker !== responseMarkerAtTrigger) {
      clearWaitingState();
    }
  });

  function triggerAgent(agent) {
    if (agent.unavailability_reason || triggeringAgent || triggeringAll || waitingForResponse) return;
    triggeringAgent = agent.id;
    beginWaiting();

    missingCredentials = [];
    void submitTrigger({ agent_id: agent.id });
  }

  function triggerAllAgents() {
    if (triggeringAgent || triggeringAll || waitingForResponse) return;
    triggeringAll = true;
    beginWaiting();

    missingCredentials = [];
    void submitTrigger({});
  }

  const isTriggering = $derived(triggeringAgent !== null || triggeringAll || waitingForResponse);
  const activeAgentIds = $derived(new Set(activeRuntimeAgentIds));
  const anyAgentActive = $derived(activeRuntimeAgentIds.length > 0);
  const anyAgentAvailable = $derived(agents.some((agent) => !agent.unavailability_reason));

  onDestroy(() => {
    if (timeoutId) clearTimeout(timeoutId);
  });
</script>

{#if agents.length > 0}
  <div class="border-t border-border px-3 md:px-6 py-3 bg-muted/20">
    {#each agents.filter((agent) => agent.inference_setup_message) as agent (agent.id)}
      <p role="status" class="mb-3 text-sm text-muted-foreground">
        {agent.name}: {agent.inference_setup_message}
        <a class="text-primary underline" href={editAccountAgentPath(accountId, agent.id)}>Edit {agent.name}</a>
      </p>
    {/each}
    <div class="flex items-center gap-2 flex-wrap">
      <span class="text-xs text-muted-foreground mr-2 hidden md:inline">Ask resident:</span>
      {#each agents as agent (agent.id)}
        {@const IconComponent = agentIconFor(agent.icon)}
        <Button
          variant="outline"
          size="sm"
          onclick={() => triggerAgent(agent)}
          disabled={disabled || isTriggering || activeAgentIds.has(agent.id) || Boolean(agent.unavailability_reason)}
          class="gap-2 {agent.colour
            ? `border-${agent.colour}-300 dark:border-${agent.colour}-700 hover:bg-${agent.colour}-50 dark:hover:bg-${agent.colour}-950`
            : ''}"
          title={agent.unavailability_reason
            ? `${agent.name} · ${agent.deprecated ? 'Deprecated · ' : ''}Unavailable`
            : activeAgentIds.has(agent.id)
              ? `${agent.name} is already running`
              : agent.name}>
          {#if triggeringAgent === agent.id || activeAgentIds.has(agent.id)}
            <Spinner size={14} class="animate-spin" />
          {:else}
            <IconComponent
              size={14}
              weight="duotone"
              class={agent.colour ? `text-${agent.colour}-600 dark:text-${agent.colour}-400` : ''} />
          {/if}
          <span class="hidden md:inline"><AgentUsageName {accountId} {agent} {showUsage} /></span>
        </Button>
      {/each}
      {#if agents.length > 1}
        <Button
          variant="default"
          size="sm"
          onclick={triggerAllAgents}
          disabled={disabled || isTriggering || anyAgentActive || !anyAgentAvailable}
          class="gap-2 ml-2"
          title="Ask All Residents">
          {#if triggeringAll}
            <Spinner size={14} class="animate-spin" />
          {:else}
            <UsersThree size={14} weight="duotone" />
          {/if}
          <span class="hidden md:inline">Ask All</span>
        </Button>
      {/if}
    </div>
  </div>
{/if}

<Dialog.Root bind:open={errorOpen}>
  <Dialog.Content class="max-w-md">
    <Dialog.Header>
      <Dialog.Title
        >{missingCredentials.length ? 'Set up resident credentials' : 'Unable to ask resident'}</Dialog.Title>
      <Dialog.Description>{triggerError}</Dialog.Description>
    </Dialog.Header>
    {#each missingCredentials as agent (agent.id)}
      <a class="text-primary underline" href={editAccountAgentPath(accountId, agent.id)}>Edit {agent.name}</a>
    {/each}
    <Dialog.Footer>
      <Button variant="outline" onclick={() => (errorOpen = false)}>Not now</Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
