<script>
  import { onMount } from 'svelte';
  import DebugPanel from './DebugPanel.svelte';
  let logs = $state([]);
  onMount(() => {
    function receive(event) {
      const { level, message, time } = event.detail;
      logs = [...logs, { level, message, time }].slice(-100);
    }
    window.addEventListener('debug-log', receive);
    return () => window.removeEventListener('debug-log', receive);
  });
</script>

<DebugPanel {logs} onclear={() => (logs = [])} />
