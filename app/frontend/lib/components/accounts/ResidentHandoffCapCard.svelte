<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import * as Card from '$lib/components/shadcn/card';
  import { accountPath } from '@/routes';

  let { accountId, cap, canManage = false } = $props();

  let value = $state(String(cap));
  let saving = $state(false);
  const parsed = $derived(Number(value));
  const valid = $derived(value !== '' && Number.isInteger(parsed) && parsed >= 0 && parsed <= 50);
  const changed = $derived(valid && parsed !== cap);

  function save(event) {
    event.preventDefault();
    if (!changed || saving) return;

    saving = true;
    router.put(
      accountPath(accountId),
      { account: { resident_handoff_cap: parsed } },
      { preserveScroll: true, onFinish: () => (saving = false) }
    );
  }
</script>

<Card.Root>
  <Card.Header>
    <Card.Title>Resident handoffs</Card.Title>
    <Card.Description>
      A resident who tags another resident (@Name) in a conversation wakes them. To stop two residents waking each other
      forever, handoffs pause after this many in a row without a message from a person, and the conversation says so. 0
      turns resident handoffs off.
    </Card.Description>
  </Card.Header>
  <Card.Content>
    {#if canManage}
      <form class="flex flex-col gap-3 sm:flex-row sm:items-end" onsubmit={save}>
        <div class="space-y-2">
          <Label for="resident-handoff-cap">Handoffs between messages from a person</Label>
          <Input
            id="resident-handoff-cap"
            type="number"
            min="0"
            max="50"
            step="1"
            class="w-32"
            bind:value
            data-testid="resident-handoff-cap" />
        </div>
        <Button type="submit" disabled={!changed || saving}>{saving ? 'Saving…' : 'Save'}</Button>
      </form>
    {:else}
      <p class="text-sm" data-testid="resident-handoff-cap-readonly">
        {cap === 0 ? 'Resident handoffs are off.' : `Up to ${cap} in a row.`}
      </p>
    {/if}
  </Card.Content>
</Card.Root>
