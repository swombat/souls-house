<script>
  import { page, router } from '@inertiajs/svelte';
  import { createDynamicSync } from '$lib/use-sync';
  import { visibleRefresh } from '$lib/visible-refresh';
  import { newAccountAgentPath, accountAgentPath, accountAgentPredecessorPath } from '@/routes';
  import { findModelLabel as modelLabelFor } from '$lib/agent-models';
  import AgentEmptyState from '$lib/components/agents/AgentEmptyState.svelte';
  import AgentGrid from '$lib/components/agents/AgentGrid.svelte';
  import AgentIndexHeader from '$lib/components/agents/AgentIndexHeader.svelte';
  import AgentUpgradeDialog from '$lib/components/agents/AgentUpgradeDialog.svelte';
  import GuestResidents from '$lib/components/agents/guest-residents.svelte';

  let {
    agents = [],
    grouped_models = {},
    account,
    resident_import_url: residentImportUrl = null,
    github_resident_import_url: githubResidentImportUrl = null,
    guest_memberships: guestMemberships = [],
    away_memberships: awayMemberships = [],
    guest_candidates: guestCandidates = [],
    can_end_guest_memberships: canEndGuestMemberships = false,
    can_manage_provider_subscription: canManageProviderSubscription = false,
    active_sessions: activeSessions = {},
  } = $props();

  // Subscribe to both:
  // - Account:${id}:agents - individual agent updates (via collection subscription)
  // - Account:${id} - new agent creation (via broadcasts_to :account)
  const updateSync = createDynamicSync();
  $effect(() => {
    updateSync({
      [`Account:${account.id}:agents`]: 'agents',
      [`Account:${account.id}`]: 'agents',
      [`ResidentSessions:${account.id}`]: 'active_sessions',
      [`GuestDirectory:${account.id}`]: [
        'guest_memberships',
        'away_memberships',
        'guest_candidates',
        'can_end_guest_memberships',
      ],
    });
  });
  // A run that ages out of the working window ends without a broadcast.
  $effect(() => visibleRefresh(['active_sessions']));
  // Discovery belongs to this human, not whichever account is being viewed.
  const updateDiscoverySync = createDynamicSync();
  $effect(() => {
    updateDiscoverySync($page.props?.user?.id ? { [`GuestDiscovery:${$page.props.user.id}`]: 'guest_candidates' } : {});
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

  function disableAgent(agent) {
    if (
      !confirm(
        `Disable resident "${agent.name}"? Their history and files will be preserved. You can re-enable them in Edit.`
      )
    )
      return;
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
  <AgentIndexHeader
    onCreate={() => router.visit(newAccountAgentPath(account.id))}
    githubImportUrl={githubResidentImportUrl}
    archiveImportUrl={residentImportUrl} />

  {#if agents.length === 0}
    <AgentEmptyState onCreate={() => router.visit(newAccountAgentPath(account.id))} />
  {:else}
    <AgentGrid
      {agents}
      {activeSessions}
      accountId={account.id}
      {canManageProviderSubscription}
      onUpgrade={openUpgradeModal}
      onDisable={disableAgent} />
  {/if}

  {#key account.id}
    <GuestResidents
      accountId={account.id}
      guests={guestMemberships}
      away={awayMemberships}
      candidates={guestCandidates}
      canEnd={canEndGuestMemberships} />
  {/key}
</div>

<AgentUpgradeDialog
  bind:open={showUpgradeModal}
  agent={upgradingAgent}
  groupedModels={grouped_models}
  bind:predecessorName
  bind:targetModel
  processing={upgradeProcessing}
  onsubmit={submitUpgrade} />
