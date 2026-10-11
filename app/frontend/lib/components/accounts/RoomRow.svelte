<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { ArrowDown, ArrowUp, Check, PencilSimple, Trash } from 'phosphor-svelte';

  let { accountId, room, first = false, last = false, canManage = false } = $props();

  let editing = $state(false);
  let name = $state('');
  const path = $derived(`/accounts/${accountId}/rooms/${room.id}`);

  function startEditing() {
    name = room.name;
    editing = true;
  }

  function rename(event) {
    event.preventDefault();
    router.patch(path, { room: { name } }, { preserveScroll: true, onSuccess: () => (editing = false) });
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
    <form class="flex flex-1 items-center gap-2" onsubmit={rename}>
      <Input bind:value={name} maxlength={40} aria-label="Room name" class="h-8" />
      <Button type="submit" size="sm" class="h-8 w-8 p-0" aria-label="Save name"><Check size={16} /></Button>
    </form>
  {:else}
    <span class="flex-1 truncate font-medium">{room.name}</span>
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
      <Button variant="ghost" size="sm" class="h-8 w-8 p-0" onclick={startEditing} aria-label="Rename {room.name}">
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
