<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { ArrowDown, ArrowUp, Check, PencilSimple, Trash } from 'phosphor-svelte';

  let { accountId, room, first = false, last = false, canManage = false } = $props();

  let editing = $state(false);
  let name = $state('');
  let description = $state('');
  const path = $derived(`/accounts/${accountId}/rooms/${room.id}`);

  function startEditing() {
    name = room.name;
    description = room.description || '';
    editing = true;
  }

  function rename(event) {
    event.preventDefault();
    router.patch(path, { room: { name, description } }, { preserveScroll: true, onSuccess: () => (editing = false) });
  }

  function move(direction) {
    router.patch(path, { direction }, { preserveScroll: true });
  }

  function remove() {
    const count = room.conversation_count;
    const message = `Remove ${room.name}? Its ${count} conversation${count === 1 ? '' : 's'} will move to Main. No conversations are deleted.`;
    if (confirm(message)) router.delete(path, { preserveScroll: true });
  }
</script>

<li class="flex items-center gap-3 px-4 py-3" data-testid="room-row">
  {#if editing}
    <form class="flex flex-1 flex-col gap-2 sm:flex-row sm:items-center" onsubmit={rename}>
      <Input bind:value={name} maxlength={40} aria-label="Room name" class="h-8 sm:w-40" />
      <Input
        bind:value={description}
        maxlength={280}
        aria-label="Use this room when"
        placeholder="Use this room when…"
        class="h-8 flex-1" />
      <Button type="submit" size="sm" class="h-8 w-8 p-0" aria-label="Save room"><Check size={16} /></Button>
    </form>
  {:else}
    <span class="min-w-0 flex-1">
      <span class="block truncate font-medium">{room.name}</span>
      {#if room.description}
        <span class="block text-sm text-muted-foreground" data-testid="room-description">
          {room.description}
        </span>
      {/if}
    </span>
    <span class="text-xs text-muted-foreground">
      {room.conversation_count} conversation{room.conversation_count === 1 ? '' : 's'}
    </span>
  {/if}
  {#if canManage && !editing}
    <div class="flex items-center gap-1">
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
      <Button variant="ghost" size="sm" class="h-8 w-8 p-0" onclick={startEditing} aria-label="Edit {room.name}">
        <PencilSimple size={14} />
      </Button>
      <Button
        variant="ghost"
        size="sm"
        class="h-8 w-8 p-0 text-destructive"
        onclick={remove}
        aria-label="Remove {room.name}">
        <Trash size={14} />
      </Button>
    </div>
  {/if}
</li>
