<script>
  import { router } from '@inertiajs/svelte';
  import { useSync } from '$lib/use-sync';
  import { newAccountAgentPath, accountAgentPath, accountAgentPredecessorPath } from '@/routes';
  import { findModelLabel as modelLabelFor } from '$lib/agent-models';
  import AgentEmptyState from '$lib/components/agents/AgentEmptyState.svelte';
  import AgentGrid from '$lib/components/agents/AgentGrid.svelte';
  import AgentIndexHeader from '$lib/components/agents/AgentIndexHeader.svelte';
  import AgentUpgradeDialog from '$lib/components/agents/AgentUpgradeDialog.svelte';

  let { agents = [], grouped_models = {}, account } = $props();

  // Subscribe to both:
  // - Account:${id}:agents - individual agent updates (via collection subscription)
  // - Account:${id} - new agent creation (via broadcasts_to :account)
  useSync({
    [`Account:${account.id}:agents`]: 'agents',
    [`Account:${account.id}`]: 'agents',
  });

  // Upgrade-with-predecessor modal state.
  // The agent the user clicked "Upgrade" on becomes the *successor* — its
  // model_id changes to targetModel, keeping its conversations, telegram bot,
  // voice. A *predecessor* is created at the current model with copied memories.
  let showUpgradeModal = $state(false);
  let upgradingAgent = $state(null);
  let predecessorName = $state('');
  let targetModel = $state('openrouter/auto');
  let upgradeProcessing = $state(false);

  // Build lookup map for tool display names

  function deleteAgent(agent) {
    if (!confirm(`Delete agent "${agent.name}"? This cannot be undone.`)) return;
    router.delete(accountAgentPath(account.id, agent.id));
  }

  function openUpgradeModal(agent) {
    upgradingAgent = agent;
    predecessorName = `${agent.name} (${modelLabelFor(grouped_models, agent.model_id)})`;
    targetModel = agent.model_id;
    showUpgradeModal = true;
  }

  function submitUpgrade() {
    if (!upgradingAgent) return;
    upgradeProcessing = true;
    router.post(
      accountAgentPredecessorPath(account.id, upgradingAgent.id),
      { to_model: targetModel, predecessor_name: predecessorName },
      {
        onFinish: () => {
          upgradeProcessing = false;
        },
        onSuccess: () => {
          showUpgradeModal = false;
          upgradingAgent = null;
        },
      }
    );
  }
</script>

<svelte:head>
  <title>Residents</title>
</svelte:head>

<div class="p-8 max-w-6xl mx-auto">
  <AgentIndexHeader onCreate={() => router.visit(newAccountAgentPath(account.id))} />

  {#if agents.length === 0}
    <AgentEmptyState onCreate={() => router.visit(newAccountAgentPath(account.id))} />
  {:else}
    <AgentGrid {agents} accountId={account.id} onUpgrade={openUpgradeModal} onDelete={deleteAgent} />
  {/if}
</div>

<AgentUpgradeDialog
  bind:open={showUpgradeModal}
  agent={upgradingAgent}
  groupedModels={grouped_models}
  bind:predecessorName
  bind:targetModel
  processing={upgradeProcessing}
  onsubmit={submitUpgrade} />
