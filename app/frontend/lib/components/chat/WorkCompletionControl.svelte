<script>
  import { onDestroy } from 'svelte';
  import * as Popover from '$lib/components/shadcn/popover/index.js';
  import { reloadProps } from '$lib/cable';

  let { chat, accountId } = $props();
  let open = $state(false);
  let receipt = $state(null);
  let busy = $state(false);
  let error = $state('');
  let draft = $state({ changes_summary: '', result: '', checks: '', remaining: '' });
  let requestKey = $state(null);
  let alive = true;
  onDestroy(() => (alive = false));
  const fields = [
    ['changes_summary', 'What changed'],
    ['result', 'Where the result is'],
    ['checks', 'What was checked'],
    ['remaining', 'Anything remaining'],
  ];
  const endpoint = $derived(`/accounts/${accountId}/chats/${chat.id}/work_completion`);
  const stale = $derived(receipt && (chat.work_status?.revision ?? 0) > receipt.work_status.revision);

  async function request(action = '', body = null, method = 'POST') {
    if (busy) return;
    busy = true;
    error = '';
    try {
      const response = await fetch(`${endpoint}${action ? `/${action}` : ''}`, {
        method: body ? method : 'GET',
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
        },
        ...(body ? { body: JSON.stringify(body) } : {}),
      });
      const result = await response.json();
      if (!alive) return;
      if (!response.ok) {
        error =
          response.status === 409
            ? 'Work changed. Refresh this panel before deciding; your draft is kept.'
            : result.error || 'Could not save. Your draft is kept.';
      } else {
        receipt = result;
        if (body && !action) requestKey = null;
        if (body) reloadProps(['chat', 'chats', 'hidden_chat_ids']);
      }
    } catch {
      if (alive) error = 'Connection failed. Your draft and retry key are kept.';
    } finally {
      if (alive) busy = false;
    }
  }

  function submit(event) {
    event.preventDefault();
    requestKey ||= crypto.randomUUID();
    request('', { ...draft, request_key: requestKey, expected_revision: receipt.work_status.revision });
  }
</script>

<Popover.Root bind:open onOpenChange={(value) => value && request()}>
  <Popover.Trigger class="rounded px-1 py-1 text-xs hover:bg-muted" aria-label="Completion handoff and review">
    Handoff / review
  </Popover.Trigger>
  <Popover.Content align="start" class="max-h-[75vh] w-96 max-w-[calc(100vw-2rem)] overflow-y-auto p-4">
    <div class="space-y-3 text-sm">
      <h3 class="font-medium">Completion handoff and review</h3>
      <p class="text-xs text-muted-foreground">
        Status reports are not acceptance. This workflow saves a handoff before accepting work or attempting closure.
      </p>
      {#if error}<p role="alert" class="text-destructive">{error}</p>{/if}
      {#if stale}<p role="alert">Work changed elsewhere. Refresh before deciding.</p>{/if}
      <button type="button" class="underline" disabled={busy} onclick={() => request()}>Refresh panel</button>
      {#if receipt}
        {#if receipt.completion}
          <section aria-label="Saved completion handoff" class="space-y-2 rounded border p-2">
            {#each fields as [key, label]}
              <p class="whitespace-pre-wrap break-words"><strong>{label}:</strong> {receipt.completion[key]}</p>
            {/each}
            {#if !receipt.completion.current}
              <p>This handoff is historical; it cannot accept the current work.</p>
            {:else if receipt.completion.accepted_at}
              <p>Accepted. {receipt.archived ? 'Conversation archived.' : 'Conversation remains open.'}</p>
              {#if !receipt.archived}
                <button
                  type="button"
                  class="rounded border p-2"
                  disabled={busy || stale}
                  onclick={() =>
                    request('close', { id: receipt.completion.id, expected_revision: receipt.work_status.revision })}>
                  Retry safe closure
                </button>
              {/if}
            {:else}
              <button
                type="button"
                class="rounded border p-2"
                disabled={busy || stale || receipt.archived}
                onclick={() =>
                  request('accept', {
                    id: receipt.completion.id,
                    expected_revision: receipt.work_status.revision,
                    auto_close: true,
                  })}>
                Accept and close if safe
              </button>
              <button
                type="button"
                class="underline"
                disabled={busy || stale || receipt.archived}
                onclick={() =>
                  request('accept', {
                    id: receipt.completion.id,
                    expected_revision: receipt.work_status.revision,
                    auto_close: false,
                  })}>
                Accept, keep open
              </button>
            {/if}
            {#if receipt.completion.closure_blocked}
              <p role="status">Closure blocked: {receipt.completion.closure_blocked.error}</p>
              {#each receipt.completion.closure_blocked.scheduled_commitments || [] as commitment}
                <p>{commitment.resident}: {commitment.headline || commitment.id}</p>
              {/each}
              {#each receipt.completion.closure_blocked.open_reply_expectations || [] as expectation}
                <p>
                  Answer still owed to {expectation.awaiting || 'a participant'} (message {expectation.message_id}).
                </p>
              {/each}
            {/if}
          </section>
        {/if}
        {#if receipt.archived}
          <p>
            Reopening preserves the reported status and handoff, but invalidates its acceptance for new work. It does
            not restore old tags or dismissed requests.
          </p>
        {:else}
          <div class="space-y-2 rounded border p-2">
            {#if receipt.permission}
              <p>No-review permission applies only to work revision {receipt.permission.revision}.</p>
              <button
                type="button"
                class="underline"
                disabled={busy || stale}
                onclick={() => request('revoke', { expected_revision: receipt.work_status.revision }, 'DELETE')}
                >Revoke permission</button>
            {:else}
              <p class="text-xs">
                Human authorisation only: allow the next handoff for this exact work revision to complete without
                another review.
              </p>
              <button
                type="button"
                class="rounded border p-2"
                disabled={busy || stale}
                onclick={() => request('grant', { expected_revision: receipt.work_status.revision, auto_close: true })}>
                Authorise completion and safe closure once
              </button>
            {/if}
          </div>
          <form onsubmit={submit} aria-label="Submit completion handoff" class="space-y-2">
            {#each fields as [key, label]}
              <label class="block"
                >{label}
                <textarea
                  bind:value={draft[key]}
                  oninput={() => (requestKey = null)}
                  required
                  maxlength="10000"
                  rows="2"
                  disabled={busy}
                  class="w-full rounded border bg-background p-2"></textarea>
              </label>
            {/each}
            <button type="submit" class="rounded border p-2" disabled={busy || stale}>Save handoff for review</button>
          </form>
        {/if}
      {/if}
    </div>
  </Popover.Content>
</Popover.Root>
