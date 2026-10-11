<script>
  import { page } from '@inertiajs/svelte';
  import RoomsPage from '../app/frontend/pages/accounts/rooms.svelte';
  import RoomSwitcher from '../app/frontend/lib/components/chat/RoomSwitcher.svelte';

  let { account, rooms = [], current_room = 'main', waiting = {}, resident_room_id = null } = $props();

  page.set({
    props: {
      account,
      rooms: rooms.map(({ id, name }) => ({ id, name })),
      current_room,
      reply_attention: { rooms: waiting },
      flash: {},
      errors: {},
    },
    component: 'accounts/rooms',
    url: `/accounts/${account.id}/rooms`,
    version: 'test',
  });
</script>

<div class="p-4 border-b" data-testid="switcher-box"><RoomSwitcher accountId={account.id} /></div>
<RoomsPage {account} {rooms} main_count={12} {resident_room_id} can_manage={true} />
