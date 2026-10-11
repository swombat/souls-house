<script>
  import { page } from '@inertiajs/svelte';
  import * as Select from '$lib/components/shadcn/select/index.js';
  import { views, roomName, visitRoom, waitingIn, ALL } from '$lib/rooms';

  // The sidebar's room switcher. It shows the same selection as the navbar's
  // Chats menu: one navigation state, stored on the server per account.
  let { accountId } = $props();

  const rooms = $derived($page.props.rooms || []);
  const current = $derived($page.props.current_room || 'main');
  const attention = $derived($page.props.reply_attention);
</script>

<Select.Root type="single" value={current} onValueChange={(key) => key !== current && visitRoom(accountId, key)}>
  <Select.Trigger
    data-testid="room-switcher"
    aria-label="Room"
    class="h-8 w-auto max-w-56 gap-2 border-0 bg-transparent px-1 text-lg font-semibold shadow-none">
    <span class="truncate">{roomName(current, rooms)}</span>
  </Select.Trigger>
  <Select.Content sideOffset={4}>
    {#each views(rooms) as option (option.id)}
      {@const waiting = option.id === ALL ? 0 : waitingIn(option.id, attention)}
      <Select.Item value={option.id} label={option.name}>
        <span class="flex w-full items-center justify-between gap-3">
          <span class="truncate">{option.name}</span>
          {#if waiting > 0}
            <span
              class="rounded-full bg-primary px-1.5 text-[10px] font-semibold leading-4 text-primary-foreground"
              title="{waiting} waiting on you">{waiting}</span>
          {/if}
        </span>
      </Select.Item>
    {/each}
  </Select.Content>
</Select.Root>
