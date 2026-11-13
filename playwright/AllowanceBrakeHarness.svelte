<script>
  import { writable } from 'svelte/store';
  import AgentAllowanceBrake from '../app/frontend/lib/components/agents/AgentAllowanceBrake.svelte';
  let { canManage = true } = $props();
  const form = writable({
    agent: { allowance_brake_threshold_percent: null, scheduled_wakes_essential: false },
    errors: {},
  });
</script>

<div class="max-w-2xl p-6">
  <AgentAllowanceBrake {form} {canManage} status={{ status: 'disabled' }} />
</div>
