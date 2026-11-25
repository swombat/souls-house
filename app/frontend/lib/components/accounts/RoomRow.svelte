<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import * as Select from '$lib/components/shadcn/select/index.js';
  import { Archive, ArrowDown, ArrowUp, ArrowCounterClockwise, Check, PencilSimple, Trash, X } from 'phosphor-svelte';
  import { MAIN } from '$lib/rooms';

  // One room on the Rooms page. `main` is the default room: no row behind it,
  // so it can be renamed and described but not moved or removed.
  let {
    accountId,
    room,
    first = false,
    last = false,
    canManage = false,
    main = false,
    mainName = 'Main',
    residentDefault = false,
    onSetResidentDefault = null,
    modelResidents = [],
    roomModelDefaults = [],
    onSetRoomModel = null,
  } = $props();
  const archived = $derived(!!room.archived);
  const roomKey = $derived(main ? MAIN : room.id);
  const DEFAULT_MODEL = 'default';

  let editing = $state(false);
  let name = $state('');
  let description = $state('');
  const path = $derived(main ? `/accounts/${accountId}/main_room` : `/accounts/${accountId}/rooms/${room.id}`);
  const count = $derived(room.conversation_count || 0);

  function startEditing() {
    name = room.name;
    description = room.description || '';
    editing = true;
  }

  function save(event) {
    event.preventDefault();
    const params = main ? { main_room: { name, description } } : { room: { name, description } };
    router.patch(path, params, { preserveScroll: true, onSuccess: () => (editing = false) });
  }

  function move(direction) {
    router.patch(path, { direction }, { preserveScroll: true });
  }

  // Archiving keeps every conversation where it is; it only stops the room
  // being a place to put new ones.
  function setArchived(value) {
    router.patch(path, { archived: value }, { preserveScroll: true });
  }

  function remove() {
    const message = `Remove ${room.name}? Its ${count} conversation${count === 1 ? '' : 's'} will move to ${mainName}. No conversations are deleted.`;
    if (confirm(message)) router.delete(path, { preserveScroll: true });
  }

  function roomDefault(resident) {
    return roomModelDefaults.find((entry) => entry.room_id === roomKey && entry.agent_id === resident.id);
  }

  function modelValue(resident) {
    return roomDefault(resident)?.model_id || DEFAULT_MODEL;
  }

  function triggerModelLabel(resident) {
    const entry = roomDefault(resident);
    return entry ? entry.label : 'Default';
  }

  function dotClass(resident) {
    return resident.colour ? `text-${resident.colour}-600 dark:text-${resident.colour}-400` : 'text-muted-foreground';
  }
</script>

<li class="px-4 py-3" data-testid={main ? 'main-room-row' : 'room-row'}>
  {#if editing}
    <form class="flex flex-col gap-2 sm:flex-row sm:items-center" onsubmit={save}>
      <Input
        bind:value={name}
        maxlength={40}
        placeholder={main ? 'Main' : undefined}
        aria-label="Room name"
        class="h-9 sm:w-40" />
      <Input
        bind:value={description}
        maxlength={280}
        aria-label="Use this room when"
        placeholder="Use this room when…"
        class="h-9 flex-1" />
      <div class="flex gap-1 self-end sm:self-auto">
        <Button
          type="button"
          variant="ghost"
          size="sm"
          class="h-9 w-9 p-0"
          onclick={() => (editing = false)}
          aria-label="Cancel editing">
          <X size={16} />
        </Button>
        <Button type="submit" size="sm" class="h-9 w-9 p-0" aria-label="Save room"><Check size={16} /></Button>
      </div>
    </form>
  {:else}
    <div class="grid grid-cols-1 gap-1.5 sm:grid-cols-[1fr_auto] sm:items-center sm:gap-x-3 sm:gap-y-1">
      <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 sm:col-start-1 sm:row-start-1">
        <span class="break-words font-medium">{room.name}</span>
        <span class="whitespace-nowrap text-xs text-muted-foreground">
          {count} conversation{count === 1 ? '' : 's'}{main ? ' · default' : ''}
        </span>
        {#if !archived && residentDefault}
          <span
            class="inline-flex items-center rounded-full border border-border bg-muted px-2 py-0.5 text-xs font-medium text-foreground"
            data-testid="resident-default-badge">
            Default for residents
          </span>
        {/if}
      </div>
      {#if room.description}
        <span
          class="block break-words text-sm text-muted-foreground sm:col-span-2 sm:row-start-2"
          data-testid="room-description">
          {room.description}
        </span>
      {/if}
      <div class="flex flex-wrap items-center justify-between gap-2 sm:col-start-2 sm:row-start-1 sm:justify-end">
        {#if archived}
          <a
            href={`/accounts/${accountId}/chats?room=${encodeURIComponent(room.id)}`}
            class="px-2 text-sm underline-offset-4 hover:underline">Open</a>
        {/if}
        {#if canManage}
          {#if !archived && !residentDefault && onSetResidentDefault}
            <Button
              variant="ghost"
              size="sm"
              class="-ml-2 h-8 px-2 text-xs text-muted-foreground hover:text-foreground sm:ml-0"
              onclick={onSetResidentDefault}
              aria-label="Set {room.name} as default room for residents">
              Set resident default
            </Button>
          {/if}
          <div class="-mr-2 ml-auto flex items-center gap-1 sm:ml-0 sm:mr-0">
            {#if archived}
              <Button
                variant="ghost"
                size="sm"
                class="h-8 w-8 p-0"
                onclick={() => setArchived(false)}
                aria-label="Unarchive {room.name}">
                <ArrowCounterClockwise size={14} />
              </Button>
            {:else if !main}
              <Button
                variant="ghost"
                size="sm"
                class="h-8 w-8 p-0"
                disabled={first}
                onclick={() => move('up')}
                aria-label="Move {room.name} up">
                <ArrowUp size={14} />
              </Button>
              <Button
                variant="ghost"
                size="sm"
                class="h-8 w-8 p-0"
                disabled={last}
                onclick={() => move('down')}
                aria-label="Move {room.name} down">
                <ArrowDown size={14} />
              </Button>
            {/if}
            <Button variant="ghost" size="sm" class="h-8 w-8 p-0" onclick={startEditing} aria-label="Edit {room.name}">
              <PencilSimple size={14} />
            </Button>
            {#if !main && !archived}
              <Button
                variant="ghost"
                size="sm"
                class="h-8 w-8 p-0"
                onclick={() => setArchived(true)}
                aria-label="Archive {room.name}">
                <Archive size={14} />
              </Button>
            {/if}
            {#if !main}
              <Button
                variant="ghost"
                size="sm"
                class="h-8 w-8 p-0 text-destructive"
                onclick={remove}
                aria-label="Remove {room.name}">
                <Trash size={14} />
              </Button>
            {/if}
          </div>
        {/if}
      </div>
      {#if !archived && modelResidents.length > 0}
        <div class="mt-1 flex flex-wrap items-start gap-2 sm:col-span-2" data-testid="room-models">
          {#each modelResidents as resident (resident.id)}
            {@const entry = roomDefault(resident)}
            <div class="w-full min-w-0 sm:w-auto">
              <Select.Root
                type="single"
                value={modelValue(resident)}
                onValueChange={(value) => onSetRoomModel?.(resident, value)}
                disabled={!canManage}>
                <Select.Trigger
                  class={`h-8 w-full max-w-full gap-1.5 px-2.5 text-xs sm:w-auto sm:max-w-[17rem] ${entry?.problem ? 'border-destructive' : ''}`}
                  title={entry
                    ? `${resident.name}: ${entry.label}`
                    : `${resident.name}: ${resident.default_label} (default)`}
                  aria-label={`${resident.name}'s model in ${room.name}`}>
                  <span class="flex min-w-0 items-center gap-1.5">
                    <span
                      data-testid="room-model-dot"
                      class={`inline-block size-2 shrink-0 rounded-full bg-current ${dotClass(resident)}`}
                      aria-hidden="true"></span>
                    <span class="shrink-0 text-muted-foreground">{resident.name}:</span>
                    <span class={`min-w-0 truncate ${entry ? 'font-medium text-foreground' : 'text-muted-foreground'}`}>
                      {triggerModelLabel(resident)}
                    </span>
                  </span>
                </Select.Trigger>
                <Select.Content sideOffset={4}>
                  <Select.Item value={DEFAULT_MODEL} label={`${resident.default_label} (default)`}>
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
            </div>
          {/each}
        </div>
      {/if}
    </div>
  {/if}
</li>
