<script>
  import AgentPaidFallbackCard from '$lib/components/agents/AgentPaidFallbackCard.svelte';
  import { Button } from '$lib/components/shadcn/button';

  let submissions = $state(0);
</script>

<form
  class="mx-auto grid max-w-2xl gap-4 p-4"
  onsubmit={(event) => {
    event.preventDefault();
    submissions += 1;
  }}>
  <AgentPaidFallbackCard url="/paid-fallback-test" agentName="Test resident" />
  <div class="flex items-center gap-3">
    <Button type="submit">Update Resident</Button>
    <output aria-label="Resident updates">{submissions}</output>
  </div>
</form>
