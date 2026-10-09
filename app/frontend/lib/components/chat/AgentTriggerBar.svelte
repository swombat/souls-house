<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Spinner, UsersThree, Warning } from 'phosphor-svelte';
  import { accountChatAgentTriggerPath, accountChatModelSelectionPath, editAccountAgentPath } from '@/routes';
  import { agentIconFor } from '$lib/agent-icons';
  import AgentUsageName from '$lib/components/chat/AgentUsageName.svelte';
  import AgentModelControl from '$lib/components/chat/AgentModelControl.svelte';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { onDestroy } from 'svelte';

  let {
    agents = [],
    accountId,
    chatId,
    showUsage = false,
    disabled = false,
    activeRuntimeAgentIds = [],
    runtimeInteractions = [],
    responseMarker = null,
    onTrigger = null,
  } = $props();
  let triggeringAgent = $state(null);
  let triggeringAll = $state(false);
  let waitingForResponse = $state(false);
  let responseMarkerAtTrigger = $state(null);
  let activeAtTrigger = new Set();
  let timeoutId = null;
  let errorOpen = $state(false);
  let errorTitle = $state('');
  let triggerError = $state('');
  let missingCredentials = $state([]);
  // Set when the house queued the ask behind a run already in progress.
  let queuedNotice = $state('');
  let queuedTimeoutId = null;
  // Selections saved from this bar, kept until the agents prop brings a newer
  // model_selection for that resident (the prop may not reload after a PATCH).
  let savedSelections = $state({});
  let savingModelFor = $state(null);

  function csrfHeaders() {
    return {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
    };
  }

  async function submitTrigger(body) {
    try {
      const response = await fetch(accountChatAgentTriggerPath(accountId, chatId), {
        method: 'POST',
        credentials: 'same-origin',
        headers: csrfHeaders(),
        body: JSON.stringify(body),
      });
      if (!response.ok) {
        const data = await response.json().catch(() => ({}));
        missingCredentials = data.code === 'missing_credentials' ? data.agents || [] : [];
        throw new Error(data.error || 'Could not ask the resident. Please try again.');
      }
      const data = (await response.json?.().catch(() => null)) || {};
      if (data.queued?.length) {
        // Nothing new starts now, so there is no response to wait for.
        clearWaitingState();
        showQueued(data.queued);
      }
      onTrigger?.();
    } catch (error) {
      clearWaitingState();
      errorTitle = '';
      triggerError = error.message;
      errorOpen = true;
    }
  }

  function showQueued(queued) {
    const names = queued.map((agent) => agent.name);
    const who = names.length > 1 ? `${names.slice(0, -1).join(', ')} and ${names.at(-1)}` : names[0];
    queuedNotice = `${who} ${names.length > 1 ? 'are' : 'is'} still responding, and will look again when that finishes.`;
    if (queuedTimeoutId) clearTimeout(queuedTimeoutId);
    queuedTimeoutId = setTimeout(() => (queuedNotice = ''), 15_000);
  }

  function selectionFor(agent) {
    const saved = savedSelections[agent.id];
    return saved && saved.base === agent.model_selection ? saved.value : agent.model_selection;
  }

  function showsModelControl(selection) {
    return Boolean(selection && (selection.choices?.length > 1 || selection.selected_by_conversation));
  }

  // The model of the turn running now, from its runtime row. Never the
  // selection: a change made mid-turn applies to the next turn only.
  function runningModelLabel(agent) {
    const row = runtimeInteractions.findLast?.((r) => r.active && r.agent_id === agent.id);
    return row?.model_label || null;
  }

  async function selectModel(agent, modelId) {
    if (savingModelFor) return;
    savingModelFor = agent.id;
    try {
      const response = await fetch(accountChatModelSelectionPath(accountId, chatId), {
        method: 'PATCH',
        credentials: 'same-origin',
        headers: csrfHeaders(),
        body: JSON.stringify({ agent_id: agent.id, model_id: modelId }),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok || !data.model_selection) {
        throw new Error(data.error || `Could not change ${agent.name}'s model. Please try again.`);
      }
      savedSelections = {
        ...savedSelections,
        [agent.id]: { base: agent.model_selection, value: data.model_selection },
      };
    } catch (error) {
      missingCredentials = [];
      errorTitle = `Unable to change ${agent.name}'s model`;
      triggerError = error.message;
      errorOpen = true;
    } finally {
      savingModelFor = null;
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
    activeAtTrigger = new Set(activeRuntimeAgentIds);
    if (timeoutId) clearTimeout(timeoutId);
    timeoutId = setTimeout(() => {
      clearWaitingState();
    }, 120_000);
  }

  // Stop waiting once the ask is taken up: streaming started (disabled), or a
  // run started that wasn't running when we asked (busy residents stay askable).
  $effect(() => {
    if (!waitingForResponse) return;
    if (disabled || activeRuntimeAgentIds.some((id) => !activeAtTrigger.has(id))) {
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
  const anyAgentAvailable = $derived(agents.some((agent) => !agent.unavailability_reason));
  const modelProblems = $derived(
    agents.map((agent) => ({ agent, selection: selectionFor(agent) })).filter(({ selection }) => selection?.problem)
  );

  onDestroy(() => {
    if (timeoutId) clearTimeout(timeoutId);
    if (queuedTimeoutId) clearTimeout(queuedTimeoutId);
  });
</script>

{#if agents.length > 0}
  <div class="border-t border-border px-3 md:px-6 py-3 bg-muted/20">
    <div class="flex items-center gap-2 flex-wrap">
      <span class="text-xs text-muted-foreground mr-2 hidden md:inline">Ask resident:</span>
      {#each agents as agent (agent.id)}
        {@const IconComponent = agentIconFor(agent.icon)}
        {@const selection = selectionFor(agent)}
        {@const withModel = showsModelControl(selection)}
        <div class="inline-flex items-center min-w-0">
          <Button
            variant="outline"
            size="sm"
            onclick={() => triggerAgent(agent)}
            disabled={disabled || isTriggering || Boolean(agent.unavailability_reason)}
            class="relative gap-2 {withModel ? 'rounded-r-none' : ''} {agent.colour
              ? `border-${agent.colour}-300 dark:border-${agent.colour}-700 hover:bg-${agent.colour}-50 dark:hover:bg-${agent.colour}-950`
              : ''}"
            title={agent.unavailability_reason
              ? `${agent.name} · ${agent.deprecated ? 'Deprecated · ' : ''}Unavailable`
              : activeAgentIds.has(agent.id)
                ? `${agent.name} is responding · ask again to have them look once more when they finish`
                : agent.name}>
            {#if triggeringAgent === agent.id || activeAgentIds.has(agent.id)}
              <Spinner size={14} class="animate-spin" />
            {:else}
              <IconComponent
                size={14}
                weight="duotone"
                class={agent.colour ? `text-${agent.colour}-600 dark:text-${agent.colour}-400` : ''} />
            {/if}
            <AgentUsageName {accountId} {agent} {showUsage} mobileGauge />
          </Button>
          {#if withModel}
            <AgentModelControl
              {agent}
              {selection}
              running={activeAgentIds.has(agent.id)}
              runningLabel={runningModelLabel(agent)}
              saving={savingModelFor === agent.id}
              onselect={(modelId) => selectModel(agent, modelId)} />
          {/if}
        </div>
      {/each}
      {#if agents.length > 1}
        <Button
          variant="default"
          size="sm"
          onclick={triggerAllAgents}
          disabled={disabled || isTriggering || !anyAgentAvailable}
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
    {#if queuedNotice}
      <div role="status" class="mt-2 text-xs text-muted-foreground">{queuedNotice}</div>
    {/if}
    {#each modelProblems as { agent, selection } (agent.id)}
      <div
        role="status"
        class="mt-2 flex flex-wrap items-center gap-x-2 gap-y-1 rounded border border-amber-500/60 bg-amber-50 px-2 py-1
               text-xs text-amber-800 dark:bg-amber-950/30 dark:text-amber-300">
        <span class="min-w-0"
          ><Warning size={12} weight="bold" class="inline-block align-[-2px] mr-1" />{agent.name}: {selection.problem}.</span>
        <button
          type="button"
          class="underline underline-offset-2 hover:no-underline disabled:opacity-50"
          disabled={savingModelFor === agent.id}
          onclick={() => selectModel(agent, 'default')}>
          Use resident default ({selection.default_label})
        </button>
      </div>
    {/each}
  </div>
{/if}

<Dialog.Root bind:open={errorOpen}>
  <Dialog.Content class="max-w-md">
    <Dialog.Header>
      <Dialog.Title
        >{missingCredentials.length
          ? 'Set up resident credentials'
          : errorTitle || 'Unable to ask resident'}</Dialog.Title>
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
