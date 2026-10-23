<script>
  import { page, router } from '@inertiajs/svelte';
  import * as DropdownMenu from '$lib/components/shadcn/dropdown-menu/index.js';
  import { Check, DoorOpen } from 'phosphor-svelte';
  import { destinations, MAIN } from '$lib/rooms';

  // The chat list's hover shortcut for "Move to room…" (desktop only; on a
  // phone the conversation menu does this). Main is a null room_id.
  let { chat, accountId, rooms = [] } = $props();
  let saving = $state(false);
  let error = $state('');
  const current = $derived(chat.room_id || MAIN);

  function move(key) {
    if (saving || key === current) return;
    saving = true;
    error = '';
    router.patch(
      `/accounts/${accountId}/chats/${chat.id}/room`,
      { room_id: key === MAIN ? null : key },
      {
        preserveScroll: true,
        preserveState: true,
        onError: () => (error = 'Could not move this conversation. Please try again.'),
        onFinish: () => (saving = false),
      }
    );
  }
</script>

<DropdownMenu.Root>
  <DropdownMenu.Trigger
    class="inline-flex h-6 w-6 shrink-0 items-center justify-center rounded text-muted-foreground hover:bg-muted hover:text-foreground focus-visible:outline focus-visible:outline-2"
    aria-label="Move to room"
    title="Move to room"
    disabled={saving}>
    <DoorOpen size={14} weight="duotone" />
  </DropdownMenu.Trigger>
  <DropdownMenu.Content align="end" class="w-44 max-h-80 overflow-y-auto">
    <DropdownMenu.Label>Move to room</DropdownMenu.Label>
    {#each destinations(rooms, $page.props.main_room_name) as option (option.id)}
      {@const here = current === option.id}
      <DropdownMenu.Item disabled={here} onclick={() => move(option.id)}>
        <span class="truncate">{option.name}</span>
        {#if here}<Check size={14} class="ml-auto shrink-0" />{/if}
      </DropdownMenu.Item>
    {/each}
  </DropdownMenu.Content>
</DropdownMenu.Root>
{#if error}
  <span
    role="alert"
    class="absolute right-0 top-full z-50 w-56 rounded border bg-background p-2 text-xs text-destructive">
    {error}
  </span>
{/if}
