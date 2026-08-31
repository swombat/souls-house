<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Spinner, UsersThree } from 'phosphor-svelte';
  import { accountChatAgentTriggerPath } from '@/routes';
  import { agentIconFor } from '$lib/agent-icons';
  import AgentUsageName from '$lib/components/chat/AgentUsageName.svelte';
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
    if (triggeringAgent || triggeringAll || waitingForResponse) return;
    triggeringAgent = agent.id;
    beginWaiting();

    router.post(
      accountChatAgentTriggerPath(accountId, chatId),
      { agent_id: agent.id },
      {
        onSuccess: () => {
          onTrigger?.();
        },
        onError: () => {
          clearWaitingState();
        },
      }
    );
  }

  function triggerAllAgents() {
    if (triggeringAgent || triggeringAll || waitingForResponse) return;
    triggeringAll = true;
    beginWaiting();

    router.post(
      accountChatAgentTriggerPath(accountId, chatId),
      {},
      {
        onSuccess: () => {
          onTrigger?.();
        },
        onError: () => {
          clearWaitingState();
        },
      }
    );
  }

  const isTriggering = $derived(triggeringAgent !== null || triggeringAll || waitingForResponse);
  const activeAgentIds = $derived(new Set(activeRuntimeAgentIds));
  const anyAgentActive = $derived(activeRuntimeAgentIds.length > 0);

  onDestroy(() => {
    if (timeoutId) clearTimeout(timeoutId);
  });
</script>

{#if agents.length > 0}
  <div class="border-t border-border px-3 md:px-6 py-3 bg-muted/20">
    <div class="flex items-center gap-2 flex-wrap">
      <span class="text-xs text-muted-foreground mr-2 hidden md:inline">Ask resident:</span>
      {#each agents as agent (agent.id)}
        {@const IconComponent = agentIconFor(agent.icon)}
        <Button
          variant="outline"
          size="sm"
          onclick={() => triggerAgent(agent)}
          disabled={disabled || isTriggering || activeAgentIds.has(agent.id)}
          class="gap-2 {agent.colour
            ? `border-${agent.colour}-300 dark:border-${agent.colour}-700 hover:bg-${agent.colour}-50 dark:hover:bg-${agent.colour}-950`
            : ''}"
          title={activeAgentIds.has(agent.id) ? `${agent.name} is already running` : agent.name}>
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
          disabled={disabled || isTriggering || anyAgentActive}
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
