<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { ArrowDown, ArrowUp, Check, PencilSimple, Trash, X } from 'phosphor-svelte';

  // One room on the Rooms page. `main` is the default room: no row behind it,
  // so it can be renamed and described but not moved or removed.
  let { accountId, room, first = false, last = false, canManage = false, main = false, mainName = 'Main' } = $props();

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

  function remove() {
    const message = `Remove ${room.name}? Its ${count} conversation${count === 1 ? '' : 's'} will move to ${mainName}. No conversations are deleted.`;
    if (confirm(message)) router.delete(path, { preserveScroll: true });
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
    <div class="flex flex-col gap-1 sm:flex-row sm:items-center sm:gap-3">
      <div class="min-w-0 flex-1">
        <span class="block break-words font-medium">{room.name}</span>
        {#if room.description}
          <span class="block break-words text-sm text-muted-foreground" data-testid="room-description">
            {room.description}
          </span>
        {/if}
      </div>
      <div class="flex items-center justify-between gap-3 sm:shrink-0 sm:justify-end">
        <span class="whitespace-nowrap text-xs text-muted-foreground">
          {count} conversation{count === 1 ? '' : 's'}{main ? ' · default' : ''}
        </span>
        {#if canManage}
          <div class="-mr-2 flex items-center gap-1 sm:mr-0">
            {#if !main}
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
    </div>
  {/if}
</li>
