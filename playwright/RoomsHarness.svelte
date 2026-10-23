<script>
  import { page } from '@inertiajs/svelte';
  import RoomsPage from '../app/frontend/pages/accounts/rooms.svelte';
  import RoomSwitcher from '../app/frontend/lib/components/chat/RoomSwitcher.svelte';
  import ChatRoomsNavMenu from '../app/frontend/lib/components/navigation/ChatRoomsNavMenu.svelte';

  let {
    account,
    rooms = [],
    current_room = 'main',
    waiting = {},
    working = { rooms: {}, all: [] },
    resident_room_id = null,
    main_room = { id: null, name: 'Main', description: null },
  } = $props();

  page.set({
    props: {
      account,
      rooms: rooms.map(({ id, name }) => ({ id, name })),
      current_room,
      main_room_name: main_room.name,
      reply_attention: { rooms: waiting },
      room_activity: working,
      flash: {},
      errors: {},
    },
    component: 'accounts/rooms',
    url: `/accounts/${account.id}/rooms`,
    version: 'test',
  });
</script>

<div class="p-4 border-b" data-testid="switcher-box"><RoomSwitcher accountId={account.id} /></div>
<div class="p-4 border-b" data-testid="nav-box"><ChatRoomsNavMenu accountId={account.id} /></div>
<RoomsPage
  {account}
  {rooms}
  room_counts={Object.fromEntries(rooms.map((room) => [room.id, room.conversation_count || 0]))}
  main_count={12}
  {main_room}
  {resident_room_id}
  can_manage={true} />
