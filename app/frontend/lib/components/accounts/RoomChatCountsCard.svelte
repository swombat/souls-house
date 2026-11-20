<script>
  import { router } from '@inertiajs/svelte';
  import * as Card from '$lib/components/shadcn/card';
  import { Switch } from '$lib/components/shadcn/switch';
  import { accountPath } from '@/routes';

  let { accountId, enabled, canManage = false } = $props();

  let saving = $state(false);

  function toggle(on) {
    if (saving) return;
    saving = true;
    router.put(
      accountPath(accountId),
      { account: { show_room_chat_counts: on } },
      { preserveScroll: true, preserveState: true, onFinish: () => (saving = false) }
    );
  }
</script>

<Card.Root>
  <Card.Header>
    <Card.Title>Conversations per room</Card.Title>
    <Card.Description>
      With this on, the room menus show how many conversations each room holds, in faint text to the left of its name.
      Archived and hidden conversations aren't counted.
    </Card.Description>
  </Card.Header>
  <Card.Content class="space-y-3">
    {#if canManage}
      <label class="flex items-center justify-between gap-3 text-sm">
        <span>Show conversations per room</span>
        <Switch
          aria-label="Show conversations per room"
          data-testid="show-room-chat-counts"
          checked={enabled}
          disabled={saving}
          onCheckedChange={toggle} />
      </label>
    {:else}
      <p class="text-sm" data-testid="show-room-chat-counts-readonly">
        {enabled
          ? 'The room menus show how many conversations each room holds.'
          : "The room menus don't show how many conversations each room holds."}
      </p>
    {/if}
  </Card.Content>
</Card.Root>
