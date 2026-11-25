<script>
  import { page, router } from '@inertiajs/svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import RoomRow from '$lib/components/accounts/RoomRow.svelte';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Plus } from 'phosphor-svelte';
  import { MAIN } from '$lib/rooms';
  import { createDynamicSync } from '$lib/use-sync';

  let {
    account,
    rooms = [],
    room_counts = {},
    main_count = 0,
    main_room = { id: null, name: 'Main', description: null },
    resident_room_id = null,
    can_manage = false,
    model_residents = [],
    room_model_defaults = [],
  } = $props();

  let name = $state('');
  let description = $state('');
  let editingAccount = account.id;
  let addRequest = 0;
  $effect(() => {
    if (editingAccount !== account.id) {
      editingAccount = account.id;
      name = '';
      description = '';
      addRequest += 1;
    }
  });
  const errors = $derived($page.props.errors || {});
  const residentRoom = $derived(resident_room_id || MAIN);
  const mainName = $derived(main_room?.name || 'Main');
  const activeRooms = $derived(rooms.filter((room) => !room.archived));
  const archivedRooms = $derived(rooms.filter((room) => room.archived));

  const updateSync = createDynamicSync();
  $effect(() => {
    updateSync({
      [`RoomNavigation:${account.id}`]: ['rooms', 'current_room', 'main_room', 'main_room_name'],
      [`Account:${account.id}`]: ['room_counts', 'main_count', 'resident_room_id', 'account', 'can_manage'],
    });
  });

  function addRoom(event) {
    event.preventDefault();
    const identity = account.id;
    const submitted = name;
    const submittedDescription = description;
    const request = ++addRequest;
    router.post(
      `/accounts/${identity}/rooms`,
      { room: { name: submitted, description: submittedDescription } },
      {
        preserveScroll: true,
        onSuccess: () => {
          if (
            account.id === identity &&
            addRequest === request &&
            name === submitted &&
            description === submittedDescription
          ) {
            name = '';
            description = '';
          }
        },
      }
    );
  }

  function setRoomModel(roomKey, resident, modelId) {
    router.patch(
      `/accounts/${account.id}/room_model_default`,
      { room_id: roomKey, agent_id: resident.id, model_id: modelId },
      { preserveScroll: true }
    );
  }

  function setResidentRoom(key) {
    router.patch(
      `/accounts/${account.id}/resident_room`,
      { room_id: key === MAIN ? null : key },
      { preserveScroll: true }
    );
  }
</script>

<svelte:head><title>Rooms · {account.name}</title></svelte:head>

<AccountSettingsLayout
  {account}
  active="rooms"
  title="Rooms"
  description="Separate places for conversations, so one kind of work doesn't bury another.">
  <FlashMessages flash={$page.props.flash} />

  <section class="space-y-3" aria-labelledby="rooms-heading">
    <h2 id="rooms-heading" class="text-xl font-semibold">Rooms</h2>
    <p class="text-sm text-muted-foreground">
      Conversations live in {mainName}, the default room, until you move them. Say what each room is for so residents
      choose the right one; mark one as the default for resident-started conversations{#if model_residents.length > 0},
        and choose starting models per room for residents with more than one{/if}. Removing a room moves its
      conversations back to {mainName}; archiving keeps them readable without showing the room in pickers.
    </p>
    <ul class="divide-y divide-border rounded-lg border border-border">
      <RoomRow
        accountId={account.id}
        room={{ ...main_room, conversation_count: main_count }}
        main
        residentDefault={residentRoom === MAIN}
        onSetResidentDefault={() => setResidentRoom(MAIN)}
        modelResidents={model_residents}
        roomModelDefaults={room_model_defaults}
        onSetRoomModel={(resident, modelId) => setRoomModel(MAIN, resident, modelId)}
        canManage={can_manage} />
      {#each activeRooms as room, index (room.id)}
        <RoomRow
          accountId={account.id}
          room={{ ...room, conversation_count: room_counts[room.id] || 0 }}
          first={index === 0}
          last={index === activeRooms.length - 1}
          {mainName}
          residentDefault={residentRoom === room.id}
          onSetResidentDefault={() => setResidentRoom(room.id)}
          modelResidents={model_residents}
          roomModelDefaults={room_model_defaults}
          onSetRoomModel={(resident, modelId) => setRoomModel(room.id, resident, modelId)}
          canManage={can_manage} />
      {/each}
      {#if can_manage}
        <li class="bg-muted/30 px-4 py-3" data-testid="add-room-row">
          <form class="flex flex-col gap-2 sm:flex-row sm:items-center" onsubmit={addRoom}>
            <Input
              bind:value={name}
              maxlength={40}
              placeholder="New room, e.g. Build"
              aria-label="New room name"
              class="h-9 bg-background sm:w-48" />
            <Input
              bind:value={description}
              maxlength={280}
              placeholder="Use this room when… (optional)"
              aria-label="New room: use this room when"
              class="h-9 flex-1 bg-background" />
            <Button type="submit" size="sm" class="h-9 sm:shrink-0" disabled={!name.trim()}>
              <Plus size={16} class="mr-1" />Add room
            </Button>
          </form>
        </li>
      {/if}
    </ul>
    {#if errors.base}
      <p role="alert" class="text-sm text-destructive">{errors.base}</p>
    {/if}
    {#if errors.name}
      <p role="alert" class="text-sm text-destructive">Name {errors.name}</p>
    {/if}
    {#if errors.description}
      <p role="alert" class="text-sm text-destructive">Description {errors.description}</p>
    {/if}
    {#if errors.main_room_name}
      <p role="alert" class="text-sm text-destructive">Name {errors.main_room_name}</p>
    {/if}
    {#if errors.main_room_description}
      <p role="alert" class="text-sm text-destructive">Description {errors.main_room_description}</p>
    {/if}
    {#if errors.room_model}
      <p role="alert" class="text-sm text-destructive">{errors.room_model}</p>
    {/if}
  </section>

  {#if archivedRooms.length > 0}
    <section class="mt-10 space-y-3" aria-labelledby="archived-rooms-heading" data-testid="archived-rooms">
      <h2 id="archived-rooms-heading" class="text-xl font-semibold">Archived rooms</h2>
      <p class="text-sm text-muted-foreground">
        Their conversations are kept and can still be read. Nothing new goes into an archived room until you unarchive
        it.
      </p>
      <ul class="divide-y divide-border rounded-lg border border-border">
        {#each archivedRooms as room (room.id)}
          <RoomRow
            accountId={account.id}
            room={{ ...room, conversation_count: room_counts[room.id] || 0 }}
            {mainName}
            canManage={can_manage} />
        {/each}
      </ul>
    </section>
  {/if}
</AccountSettingsLayout>
