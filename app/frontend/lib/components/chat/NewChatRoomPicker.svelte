<script>
  import { page } from '@inertiajs/svelte';
  import * as Select from '$lib/components/shadcn/select/index.js';
  import { destinations, roomName } from '$lib/rooms';

  // Where a new conversation will live. Hidden until the account has rooms.
  let { roomId = $bindable('main') } = $props();

  const rooms = $derived($page.props.rooms || []);
</script>

{#if rooms.length > 0}
  <div class="flex items-center gap-2 px-4 pt-2 text-xs text-muted-foreground">
    <span>Room</span>
    <Select.Root type="single" bind:value={roomId}>
      <Select.Trigger class="h-7 w-40 text-xs" aria-label="Room for this conversation" data-testid="new-chat-room">
        {roomName(roomId, rooms)}
      </Select.Trigger>
      <Select.Content sideOffset={4}>
        {#each destinations(rooms) as option (option.id)}
          <Select.Item value={option.id} label={option.name}>{option.name}</Select.Item>
        {/each}
      </Select.Content>
    </Select.Root>
  </div>
{/if}
