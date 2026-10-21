<script>
  import { page, router } from '@inertiajs/svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import RoomRow from '$lib/components/accounts/RoomRow.svelte';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import * as Select from '$lib/components/shadcn/select/index.js';
  import { Plus } from 'phosphor-svelte';
  import { destinations, roomName, MAIN } from '$lib/rooms';
  import { createDynamicSync } from '$lib/use-sync';

  let {
    account,
    rooms = [],
    room_counts = {},
    main_count = 0,
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

  const updateSync = createDynamicSync();
  $effect(() => {
    updateSync({
      [`RoomNavigation:${account.id}`]: ['rooms', 'current_room'],
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

  const DEFAULT = 'default';

  function roomDefault(roomKey, resident) {
    return room_model_defaults.find((entry) => entry.room_id === roomKey && entry.agent_id === resident.id);
  }

  function modelValue(roomKey, resident) {
    return roomDefault(roomKey, resident)?.model_id || DEFAULT;
  }

  function modelLabel(roomKey, resident) {
    const entry = roomDefault(roomKey, resident);
    if (!entry) return `${resident.default_label} (default)`;
    return entry.label;
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
      Conversations live in Main until you move them. Once you add a room, the Chats menu and the conversation list let
      you switch between rooms or view all chats at once. Removing a room moves its conversations back to Main; none are
      deleted. Say what each room is for, and residents will read it when they choose where a conversation goes.
    </p>
    <ul class="divide-y divide-border rounded-lg border border-border">
      <li class="flex items-center gap-3 px-4 py-3">
        <span class="flex-1 font-medium">Main</span>
        <span class="text-xs text-muted-foreground">
          {main_count} conversation{main_count === 1 ? '' : 's'} · default
        </span>
      </li>
      {#each rooms as room, index (room.id)}
        <RoomRow
          accountId={account.id}
          room={{ ...room, conversation_count: room_counts[room.id] || 0 }}
          first={index === 0}
          last={index === rooms.length - 1}
          canManage={can_manage} />
      {/each}
    </ul>
    {#if errors.name}
      <p role="alert" class="text-sm text-destructive">Name {errors.name}</p>
    {/if}
    {#if errors.description}
      <p role="alert" class="text-sm text-destructive">Description {errors.description}</p>
    {/if}
    {#if can_manage}
      <form class="flex max-w-2xl flex-col gap-2 sm:flex-row sm:items-center" onsubmit={addRoom}>
        <Input
          bind:value={name}
          maxlength={40}
          placeholder="New room, e.g. Build"
          aria-label="New room name"
          class="sm:w-48" />
        <Input
          bind:value={description}
          maxlength={280}
          placeholder="Use this room when… (optional)"
          aria-label="New room: use this room when"
          class="flex-1" />
        <Button type="submit" disabled={!name.trim()}><Plus size={16} class="mr-1" />Add room</Button>
      </form>
    {/if}
  </section>

  <section class="mt-10 space-y-3" aria-labelledby="resident-room-heading">
    <h2 id="resident-room-heading" class="text-xl font-semibold">Default room for residents</h2>
    <p class="text-sm text-muted-foreground">
      Where a conversation lands when a resident starts it without choosing a room. Residents can still choose any room,
      including Main, and anyone can move a conversation afterwards. This doesn't change where you arrive: the Chats
      menu remembers the room you last opened.
    </p>
    {#if rooms.length === 0}
      <p class="text-sm text-muted-foreground" data-testid="resident-room-empty">
        Resident-started conversations go to Main. Add a room above to send them somewhere else.
      </p>
    {:else}
      <Select.Root type="single" value={residentRoom} onValueChange={setResidentRoom} disabled={!can_manage}>
        <Select.Trigger class="w-56" aria-label="Default room for resident-started conversations">
          {roomName(residentRoom, rooms)}
        </Select.Trigger>
        <Select.Content sideOffset={4}>
          {#each destinations(rooms) as option (option.id)}
            <Select.Item value={option.id} label={option.name}>{option.name}</Select.Item>
          {/each}
        </Select.Content>
      </Select.Root>
    {/if}
  </section>

  {#if model_residents.length > 0}
    <section class="mt-10 space-y-3" aria-labelledby="room-models-heading" data-testid="room-models">
      <h2 id="room-models-heading" class="text-xl font-semibold">Models by room</h2>
      <p class="text-sm text-muted-foreground">
        The model each resident starts on in a new conversation in this room. Anyone in the conversation can still
        change it from the resident's button. Changing it here doesn't touch existing conversations, and a conversation
        moved into a room keeps the model it had. Only residents with more than one model for conversations are listed.
      </p>
      {#if errors.room_model}
        <p role="alert" class="text-sm text-destructive">{errors.room_model}</p>
      {/if}
      <div class="overflow-x-auto rounded-lg border border-border">
        <table class="w-full text-sm">
          <thead>
            <tr class="border-b border-border text-left">
              <th class="px-4 py-2 font-medium">Room</th>
              {#each model_residents as resident (resident.id)}
                <th class="px-4 py-2 font-medium">{resident.name}</th>
              {/each}
            </tr>
          </thead>
          <tbody class="divide-y divide-border">
            {#each destinations(rooms) as option (option.id)}
              <tr>
                <td class="px-4 py-2 font-medium">{option.name}</td>
                {#each model_residents as resident (resident.id)}
                  {@const entry = roomDefault(option.id, resident)}
                  <td class="px-4 py-2">
                    <Select.Root
                      type="single"
                      value={modelValue(option.id, resident)}
                      onValueChange={(value) => setRoomModel(option.id, resident, value)}
                      disabled={!can_manage}>
                      <Select.Trigger class="w-52" aria-label={`${resident.name}'s model in ${option.name}`}>
                        {modelLabel(option.id, resident)}
                      </Select.Trigger>
                      <Select.Content sideOffset={4}>
                        <Select.Item value={DEFAULT} label={`${resident.default_label} (default)`}>
                          {resident.default_label} (default)
                        </Select.Item>
                        {#each resident.choices.slice(1) as choice (choice.model_id)}
                          <Select.Item value={choice.model_id} label={choice.label}>{choice.label}</Select.Item>
                        {/each}
                      </Select.Content>
                    </Select.Root>
                    {#if entry?.problem}
                      <p class="mt-1 text-xs text-destructive">{entry.problem}; new conversations use the default.</p>
                    {/if}
                  </td>
                {/each}
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    </section>
  {/if}
</AccountSettingsLayout>
