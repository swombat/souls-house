<script>
  import { Hammer, Eye, Play, Stop, CheckCircle, Pause } from 'phosphor-svelte';
  import { workStatusInfo } from '$lib/work-status';

  let { state, size = 16 } = $props();
  const info = $derived(workStatusInfo(state));
  const icons = { Hammer, Eye, Play, Stop, CheckCircle, Pause };
  const Icon = $derived(info ? icons[info.icon] : null);
</script>

{#if Icon}
  <span class={`inline-flex shrink-0 ${info.colour}`} aria-hidden="true">
    <Icon {size} weight="fill" />
  </span>
{/if}
