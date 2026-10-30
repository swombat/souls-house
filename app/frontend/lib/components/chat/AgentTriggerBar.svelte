<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Spinner, UsersThree } from 'phosphor-svelte';
  import { accountChatAgentTriggerPath, accountChatModelSelectionPath, editAccountAgentPath } from '@/routes';
  import AgentAvatar from '$lib/components/agents/AgentAvatar.svelte';
  import AgentUsageName from '$lib/components/chat/AgentUsageName.svelte';
  import AgentModelControl from '$lib/components/chat/AgentModelControl.svelte';
  import AgentModelProblems from '$lib/components/chat/AgentModelProblems.svelte';
  import { sortAgentsByAvailability, watchAgentsRemaining } from '$lib/agent-subscription-usage';
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
    // The newest resident reply as { id, agentId }; releases an external
    // resident (who posts a finished message and leaves no run) only when
    // the reply is theirs.
    lastReply = null,
    onTrigger = null,
  } = $props();
  // One entry per resident asked and not yet taken up, so asking one resident
  // never holds the others' buttons. Each entry remembers what the room looked
  // like when that resident was asked: whether it was running, its runtime
  // rows, and the reply marker.
  let pending = $state({});
  let triggeringAll = $state(false);
  const pendingTimeouts = new Map();
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
  let remainingById = $state({});
  let sortedAgents = $derived(sortAgentsByAvailability(agents, remainingById));

  $effect(() =>
    watchAgentsRemaining(accountId, agents, (id, value) => {
      if (remainingById[id] !== value) remainingById = { ...remainingById, [id]: value };
    })
  );

  function csrfHeaders() {
    return {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
    };
  }

  async function submitTrigger(body, ids) {
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
        // Nothing new starts now for these, so there is no response to wait for.
        clearPending(data.queued.map((agent) => agent.id));
        showQueued(data.queued);
      }
      onTrigger?.();
    } catch (error) {
      clearPending(ids);
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

  function rowIdsFor(agentId) {
    return new Set(runtimeInteractions.filter((row) => row.agent_id === agentId).map((row) => row.id));
  }

  function clearPending(ids) {
    const next = { ...pending };
    for (const id of ids) {
      delete next[id];
      clearTimeout(pendingTimeouts.get(id));
      pendingTimeouts.delete(id);
    }
    pending = next;
  }

  function beginPending(ids) {
    const next = { ...pending };
    for (const id of ids) {
      next[id] = {
        wasActive: activeRuntimeAgentIds.includes(id),
        rowIds: rowIdsFor(id),
        replyId: lastReply?.id ?? null,
      };
      clearTimeout(pendingTimeouts.get(id));
      pendingTimeouts.set(
        id,
        setTimeout(() => clearPending([id]), 120_000)
      );
    }
    pending = next;
  }

  // A resident's ask is taken up once a run of theirs starts that wasn't
  // running when they were asked, or a new runtime row of theirs appears.
  // External residents post a finished message instead of running here, so
  // their own new reply releases them. Only that resident's button is released.
  $effect(() => {
    const ids = Object.keys(pending);
    if (!ids.length) return;
    if (disabled) return clearPending(ids);
    const taken = ids.filter((id) => {
      const entry = pending[id];
      if (activeRuntimeAgentIds.includes(id) && !entry.wasActive) return true;
      if (runtimeInteractions.some((row) => row.agent_id === id && !entry.rowIds.has(row.id))) return true;
      return lastReply?.agentId === id && lastReply.id !== entry.replyId;
    });
    if (taken.length) clearPending(taken);
  });

  function triggerAgent(agent) {
    if (agent.unavailability_reason || pending[agent.id]) return;
    beginPending([agent.id]);

    missingCredentials = [];
    void submitTrigger({ agent_id: agent.id }, [agent.id]);
  }

  // Ask All asks every resident in the room, so it waits while any single
  // ask is still starting: otherwise that resident would be asked twice.
  function triggerAllAgents() {
    if (triggeringAll || anyPending) return;
    const ids = agents.filter((agent) => !agent.unavailability_reason).map((agent) => agent.id);
    if (!ids.length) return;
    triggeringAll = true;
    beginPending(ids);

    missingCredentials = [];
    void submitTrigger({}, ids).finally(() => (triggeringAll = false));
  }

  const anyPending = $derived(Object.keys(pending).length > 0);

  const activeAgentIds = $derived(new Set(activeRuntimeAgentIds));
  const anyAgentAvailable = $derived(agents.some((agent) => !agent.unavailability_reason));
  const modelProblems = $derived(
    agents.map((agent) => ({ agent, selection: selectionFor(agent) })).filter(({ selection }) => selection?.problem)
  );

  onDestroy(() => {
    for (const id of pendingTimeouts.values()) clearTimeout(id);
    if (queuedTimeoutId) clearTimeout(queuedTimeoutId);
  });
</script>

{#if agents.length > 0}
  <div class="border-t border-border px-3 md:px-6 py-3 bg-muted/20">
    <div class="flex items-center gap-2 flex-wrap">
      <span class="text-xs text-muted-foreground mr-2 hidden md:inline">Ask resident:</span>
      {#each sortedAgents as agent (agent.id)}
        {@const selection = selectionFor(agent)}
        {@const withModel = showsModelControl(selection)}
        <div class="inline-flex items-center min-w-0">
          <Button
            variant="outline"
            size="sm"
            onclick={() => triggerAgent(agent)}
            disabled={disabled || Boolean(pending[agent.id]) || Boolean(agent.unavailability_reason)}
            class="relative gap-2 {withModel ? 'rounded-r-none' : ''} {agent.colour
              ? `border-${agent.colour}-300 dark:border-${agent.colour}-700 hover:bg-${agent.colour}-50 dark:hover:bg-${agent.colour}-950`
              : ''}"
            title={agent.unavailability_reason
              ? `${agent.name} · ${agent.deprecated ? 'Deprecated · ' : ''}Unavailable`
              : activeAgentIds.has(agent.id)
                ? `${agent.name} is responding · ask again to have them look once more when they finish`
                : agent.name}>
            {#if pending[agent.id] || activeAgentIds.has(agent.id)}
              <Spinner size={14} class="animate-spin" />
            {:else}
              <AgentAvatar
                {agent}
                class="w-4 h-4 rounded-full flex items-center justify-center"
                iconClass={agent.colour ? `text-${agent.colour}-600 dark:text-${agent.colour}-400` : ''}
                iconSize={14} />
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
          disabled={disabled || triggeringAll || anyPending || !anyAgentAvailable}
          class="gap-2 ml-2"
          title={anyPending ? 'Ask All waits until the residents you asked have started' : 'Ask All Residents'}>
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
    <AgentModelProblems
      problems={modelProblems}
      savingFor={savingModelFor}
      onusedefault={(agent) => selectModel(agent, 'default')} />
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
