<script>
  import { agentNameWithUsage, loadAgentWeeklyRemaining } from '$lib/agent-subscription-usage';

  let { accountId, agent, showUsage = false } = $props();
  let remaining = $state(null);
  let label = $derived(agentNameWithUsage(agent.name, remaining, showUsage));

  $effect(() => {
    let cancelled = false;

    loadAgentWeeklyRemaining(accountId, agent).then((value) => {
      if (!cancelled) remaining = value;
    });

    return () => {
      cancelled = true;
    };
  });
</script>

{label}
