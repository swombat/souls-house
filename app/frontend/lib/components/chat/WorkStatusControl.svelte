<script>
  import { onDestroy } from 'svelte';
  import * as Popover from '$lib/components/shadcn/popover/index.js';
  import { reloadProps } from '$lib/cable';
  import { WORK_STATUSES, workStatusInfo, workStatusDate } from '$lib/work-status';
  import WorkStatusSummary from './WorkStatusSummary.svelte';

  let { chat, accountId } = $props();
  let open = $state(false);
  let draftState = $state('');
  let draftReason = $state('');
  let expectedRevision = $state(0);
  let saving = $state(false);
  let error = $state('');
  let confirmed = $state(null);
  let alive = true;
  onDestroy(() => (alive = false));

  const current = $derived(
    confirmed && (chat.work_status?.revision ?? 0) < confirmed.revision ? confirmed : chat.work_status
  );
  const requiresReason = $derived(['needs_input', 'blocked'].includes(draftState));

  function begin(value) {
    if (!value) return;
    draftState = current?.state || '';
    draftReason = current?.reason || '';
    expectedRevision = current?.revision ?? 0;
    error = '';
  }

  async function save(event) {
    event.preventDefault();
    if (saving) return;
    saving = true;
    error = '';
    try {
      const response = await fetch(`/accounts/${accountId}/chats/${chat.id}/work_status`, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
        },
        body: JSON.stringify({
          state: draftState || null,
          reason: draftState ? draftReason.trim() || null : null,
          expected_revision: expectedRevision,
        }),
      });
      const result = await response.json();
      if (!alive) return;
      if (response.status === 409) {
        error = 'The status changed elsewhere. Close and reopen this form to review the latest status before saving.';
        if (result.work_status) confirmed = result.work_status;
        reloadProps(['chat', 'chats', 'hidden_chat_ids']);
      } else if (!response.ok || !result.work_status) {
        error = 'Could not save work status. Check the reason and try again.';
      } else {
        confirmed = result.work_status;
        open = false;
        reloadProps(['chat', 'chats', 'hidden_chat_ids']);
      }
    } catch {
      if (alive) error = 'Could not save work status. Your draft is kept; check the connection and try again.';
    } finally {
      if (alive) saving = false;
    }
  }
</script>

<Popover.Root bind:open onOpenChange={begin}>
  <Popover.Trigger
    class="max-w-full rounded px-1 py-1 text-left hover:bg-muted focus-visible:outline focus-visible:outline-2"
    aria-label={`Change work status: ${workStatusInfo(current?.state)?.label || 'Not declared'}`}
    disabled={chat.discarded || chat.archived}>
    {#if current?.state}
      <WorkStatusSummary status={current} compact />
    {:else}
      <span class="text-xs text-muted-foreground">Track work</span>
    {/if}
  </Popover.Trigger>
  <Popover.Content align="start" class="w-80 max-w-[calc(100vw-2rem)] p-4">
    <form onsubmit={save} aria-label="Change work status" class="space-y-3">
      <p class="text-sm font-medium">Reported work status</p>
      <p class="text-xs text-muted-foreground">
        A shared declaration, not live runtime activity. Completed does not accept, hide or archive the conversation.
      </p>
      {#if current?.since}
        <p class="text-xs text-muted-foreground">Current report since {workStatusDate(current.since)}</p>
      {/if}
      {#if current?.human_replied_since}
        <p class="text-xs text-amber-700 dark:text-amber-400">
          A human replied at {workStatusDate(current.human_replied_since)}. This does not prove the question or blocker
          is resolved.
        </p>
      {/if}
      <label class="block space-y-1 text-sm">
        <span>Status</span>
        <select bind:value={draftState} disabled={saving} class="w-full rounded border border-input bg-background p-2">
          <option value="">Not declared / stop tracking</option>
          {#each WORK_STATUSES as status (status.state)}
            <option value={status.state}>{status.label}</option>
          {/each}
        </select>
      </label>
      {#if draftState}
        <label class="block space-y-1 text-sm">
          <span>Reason {requiresReason ? '(required)' : '(optional)'}</span>
          <textarea
            bind:value={draftReason}
            required={requiresReason}
            maxlength="1000"
            rows="3"
            disabled={saving}
            class="w-full rounded border border-input bg-background p-2"
            placeholder={draftState === 'needs_input'
              ? 'The specific question or decision needed'
              : 'What is happening, or what is missing'}></textarea>
        </label>
      {/if}
      {#if chat.visual_tag?.hides_from_list}
        <p class="text-xs text-muted-foreground">
          Tracking work keeps this conversation listed despite its hidden tag. Stopping tracking restores the tag’s
          hiding behavior.
        </p>
      {/if}
      {#if error}<p role="alert" class="text-sm text-destructive">{error}</p>{/if}
      <div class="flex justify-end gap-2">
        <button
          type="button"
          onclick={() => (open = false)}
          disabled={saving}
          class="rounded border px-3 py-1.5 text-sm">Cancel</button>
        <button type="submit" disabled={saving} class="rounded bg-primary px-3 py-1.5 text-sm text-primary-foreground">
          {saving ? 'Saving…' : 'Save status'}
        </button>
      </div>
    </form>
  </Popover.Content>
</Popover.Root>
