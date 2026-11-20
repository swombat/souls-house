<script>
  import { page } from '@inertiajs/svelte';
  import * as Select from '$lib/components/shadcn/select/index.js';
  import RoomChatCount from './RoomChatCount.svelte';
  import { views, roomName, visitRoom, chatsIn } from '$lib/rooms';

  // The mobile shortcut to the same active room as the sidebar.
  let { accountId } = $props();

  const rooms = $derived($page.props.rooms || []);
  const mainName = $derived($page.props.main_room_name);
  const current = $derived($page.props.current_room || 'main');
  const counts = $derived($page.props.room_chat_counts);
</script>

{#if rooms.length > 0}
  <div class="flex items-center gap-2 text-xs text-muted-foreground md:hidden">
    <span class="hidden sm:inline">Room</span>
    <Select.Root type="single" value={current} onValueChange={(key) => key !== current && visitRoom(accountId, key)}>
      <Select.Trigger class="h-7 w-32 sm:w-40 text-xs" aria-label="Room" data-testid="new-chat-room">
        {roomName(current, rooms, mainName)}
      </Select.Trigger>
      <Select.Content sideOffset={4}>
        {#each views(rooms, mainName) as option (option.id)}
          <Select.Item value={option.id} label={option.name}>
            <span class="flex min-w-0 items-center gap-2">
              <span class="truncate">{option.name}</span>
              <RoomChatCount count={chatsIn(option.id, counts)} class="order-first" />
            </span>
          </Select.Item>
        {/each}
      </Select.Content>
    </Select.Root>
  </div>
{/if}
