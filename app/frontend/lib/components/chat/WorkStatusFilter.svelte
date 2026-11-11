<script>
  import { WORK_STATUSES } from '$lib/work-status';
  import WorkStatusIcon from './WorkStatusIcon.svelte';
  let { selected = '', replied = false, onSelect = () => {}, onToggleReplied = () => {} } = $props();
</script>

<div class="space-y-2 border-t border-border pt-2" data-testid="work-status-filter">
  <label class="block px-1 text-xs text-muted-foreground">
    <span>Work status</span>
    <select
      value={selected}
      onchange={(event) => onSelect(event.currentTarget.value)}
      class="mt-1 w-full rounded border border-input bg-background p-1.5 text-sm text-foreground">
      <option value="">All statuses</option>
      <option value="needs_me">Needs me (your input or review)</option>
      {#each WORK_STATUSES as status (status.state)}
        <option value={status.state}>{status.label}</option>
      {/each}
      <option value="untracked">Not declared</option>
    </select>
  </label>
  {#if selected && selected !== 'untracked' && selected !== 'needs_me'}
    <div class="flex items-center gap-1.5 px-1 text-xs">
      <WorkStatusIcon state={selected} />
      <span>{WORK_STATUSES.find((status) => status.state === selected)?.label}</span>
    </div>
  {/if}
  <label class="flex items-start gap-2 px-1 text-sm">
    <input type="checkbox" checked={replied} onchange={onToggleReplied} class="mt-1" />
    <span>Human replied since request or blocker</span>
  </label>
  <p class="px-1 text-xs text-muted-foreground">
    Reports are separate from unanswered-request flags and live activity.
  </p>
</div>
