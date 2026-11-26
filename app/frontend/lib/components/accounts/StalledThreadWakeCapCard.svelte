<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import * as Card from '$lib/components/shadcn/card';
  import { accountPath } from '@/routes';
  import { createAccountSettingDraft } from '$lib/account-setting-draft.svelte.js';

  let { accountId, cap, canManage = false } = $props();

  const draft = createAccountSettingDraft(
    () => accountId,
    () => cap
  );
  const parsed = $derived(Number(draft.value));
  const valid = $derived(draft.value !== '' && Number.isInteger(parsed) && parsed >= 0 && parsed <= 50);
  const changed = $derived(valid && parsed !== cap);

  function save(event) {
    event.preventDefault();
    if (!changed || draft.saving) return;

    draft.save(
      (value, options) =>
        router.put(accountPath(accountId), { account: { stalled_thread_wake_cap: Number(value) } }, options),
      (response) => response.props.stalled_thread_wake_cap
    );
  }
</script>

<Card.Root>
  <Card.Header>
    <Card.Title>Stalled-thread wakes</Card.Title>
    <Card.Description>
      When a quiet conversation still looks like a resident has a step to take, the stalled-thread check wakes them. To
      stop a stuck conversation waking residents forever, the check stops after waking the same resident this many times
      without a message from a person, and the conversation says so. 0 turns stalled-thread wakes off.
    </Card.Description>
  </Card.Header>
  <Card.Content>
    {#if canManage}
      <form class="flex flex-col gap-3 sm:flex-row sm:items-end" onsubmit={save}>
        <div class="space-y-2">
          <Label for="stalled-thread-wake-cap">Wakes per resident between messages from a person</Label>
          <Input
            id="stalled-thread-wake-cap"
            type="number"
            min="0"
            max="50"
            step="1"
            class="w-32"
            bind:value={draft.value}
            data-testid="stalled-thread-wake-cap" />
        </div>
        <Button type="submit" disabled={!changed || draft.saving}>{draft.saving ? 'Saving…' : 'Save'}</Button>
      </form>
    {:else}
      <p class="text-sm" data-testid="stalled-thread-wake-cap-readonly">
        {cap === 0
          ? 'Stalled-thread wakes are off.'
          : cap === 1
            ? 'Up to 1 wake per resident.'
            : `Up to ${cap} wakes per resident.`}
      </p>
    {/if}
  </Card.Content>
</Card.Root>
