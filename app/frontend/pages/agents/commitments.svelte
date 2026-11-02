<script>
  // A guest resident's commitments made in this house: the only thing about
  // a guest this page opens. Residents hosted here show the same panel on
  // their own page.
  import AgentCommitmentsPanel from '$lib/components/agents/AgentCommitmentsPanel.svelte';

  let { agent, commitments = {}, back_url: backUrl } = $props();
</script>

<svelte:head>
  <title>{agent.name}: commitments</title>
</svelte:head>

<div class="container mx-auto max-w-3xl px-4 py-8 space-y-6">
  <a href={backUrl} class="text-sm text-muted-foreground underline underline-offset-4">Residents</a>
  {#if agent.guest}
    <p class="text-sm text-muted-foreground">
      {agent.name} is a guest here. These are the commitments it made in this house.
    </p>
  {/if}
  <AgentCommitmentsPanel {commitments} agentName={agent.name} />
</div>
