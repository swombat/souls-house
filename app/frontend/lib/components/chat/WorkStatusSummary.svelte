<script>
  import WorkStatusIcon from './WorkStatusIcon.svelte';
  import { workStatusInfo, workStatusDescription } from '$lib/work-status';
  let { status, compact = false, showIcon = true } = $props();
  const info = $derived(workStatusInfo(status?.state));
</script>

{#if info}
  <span
    class="flex min-w-0 flex-wrap items-center gap-x-1.5 gap-y-0.5 text-xs"
    data-testid="work-status-summary"
    title={workStatusDescription(status)}
    aria-label={workStatusDescription(status)}>
    {#if showIcon}<WorkStatusIcon state={status.state} />{/if}
    <span class="truncate">{info.label}</span>
    {#if !compact && status.reason}<span class="truncate text-muted-foreground">· {status.reason}</span>{/if}
    {#if status.human_replied_since}
      <span class="text-amber-700 dark:text-amber-400">· Human replied since</span>
    {/if}
  </span>
{/if}
