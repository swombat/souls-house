<script>
  import { page, router } from '@inertiajs/svelte';
  import * as Select from '$lib/components/shadcn/select/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { destinations, MAIN } from '$lib/rooms';

  // Bulk "Move to…" for the conversations selected in the list.
  let { accountId, selectedIds = [], onDone = () => {} } = $props();

  const rooms = $derived($page.props.rooms || []);
  let processing = $state(false);

  function move(key) {
    if (!selectedIds.length || processing) return;
    processing = true;
    router.post(
      `/accounts/${accountId}/chats/move`,
      { chat_ids: selectedIds, room_id: key === MAIN ? null : key },
      { preserveScroll: true, onSuccess: onDone, onFinish: () => (processing = false) }
    );
  }
</script>

{#if $page.props.errors?.chat_ids || $page.props.errors?.room_id}
  <p role="alert" class="border-t border-border px-3 pt-2 text-xs text-destructive">
    {$page.props.errors.chat_ids || $page.props.errors.room_id}
  </p>
{/if}
<div class="border-t border-border bg-muted/30 p-3 flex items-center gap-2" data-testid="room-move-bar">
  <span class="text-xs text-muted-foreground flex-1">{selectedIds.length} selected</span>
  <Select.Root type="single" onValueChange={move}>
    <Select.Trigger class="h-8 w-36" disabled={!selectedIds.length || processing} aria-label="Move to room">
      Move to…
    </Select.Trigger>
    <Select.Content sideOffset={4}>
      {#each destinations(rooms) as option (option.id)}
        <Select.Item value={option.id} label={option.name}>{option.name}</Select.Item>
      {/each}
    </Select.Content>
  </Select.Root>
  <Button variant="ghost" size="sm" class="h-8" onclick={onDone}>Cancel</Button>
</div>
