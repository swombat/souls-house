<script>
  import { page, router } from '@inertiajs/svelte';
  import * as DropdownMenu from '$lib/components/shadcn/dropdown-menu/index.js';
  import { Archive, Check, DotsThree } from 'phosphor-svelte';
  import { accountChatArchivePath } from '@/routes';
  import { destinations, MAIN } from '$lib/rooms';

  // The chat list's hover menu for a conversation (desktop only; on a phone
  // the conversation menu does this). Archive is always there; "Move to room"
  // only when the account has a room besides Main. Main is a null room_id.
  let { chat, accountId, rooms = [] } = $props();
  let saving = $state(false);
  let error = $state('');
  const current = $derived(chat.room_id || MAIN);
  // Its own name per row: the header's menu is "Conversation actions", and
  // page-wide locators for that name must still find exactly one button.
  const label = $derived(`Actions for ${chat.title_or_default || chat.title || 'New Chat'}`);

  const options = (failure) => ({
    preserveScroll: true,
    preserveState: true,
    onError: () => (error = failure),
    onFinish: () => (saving = false),
  });

  function move(key) {
    if (saving || key === current) return;
    saving = true;
    error = '';
    router.patch(
      `/accounts/${accountId}/chats/${chat.id}/room`,
      { room_id: key === MAIN ? null : key },
      options('Could not move this conversation. Please try again.')
    );
  }

  function toggleArchive() {
    if (saving) return;
    saving = true;
    error = '';
    const path = accountChatArchivePath(accountId, chat.id);
    const failure = `Could not ${chat.archived ? 'unarchive' : 'archive'} this conversation. Please try again.`;
    if (chat.archived) router.delete(path, options(failure));
    else router.post(path, {}, options(failure));
  }
</script>

<DropdownMenu.Root>
  <DropdownMenu.Trigger
    class="inline-flex h-6 w-6 shrink-0 items-center justify-center rounded text-muted-foreground hover:bg-muted hover:text-foreground focus-visible:outline focus-visible:outline-2"
    aria-label={label}
    title={label}
    disabled={saving}>
    <DotsThree size={16} weight="bold" />
  </DropdownMenu.Trigger>
  <DropdownMenu.Content align="end" class="w-44 max-h-80 overflow-y-auto">
    <DropdownMenu.Item onclick={toggleArchive}>
      <Archive size={14} class="mr-2 shrink-0" weight="duotone" />
      {chat.archived ? 'Unarchive' : 'Archive'}
    </DropdownMenu.Item>
    {#if rooms.length > 0}
      <DropdownMenu.Separator />
      <DropdownMenu.Label>Move to room</DropdownMenu.Label>
      {#each destinations(rooms, $page.props.main_room_name) as option (option.id)}
        {@const here = current === option.id}
        <DropdownMenu.Item disabled={here} onclick={() => move(option.id)}>
          <span class="truncate">{option.name}</span>
          {#if here}<Check size={14} class="ml-auto shrink-0" />{/if}
        </DropdownMenu.Item>
      {/each}
    {/if}
  </DropdownMenu.Content>
</DropdownMenu.Root>
{#if error}
  <span
    role="alert"
    class="absolute right-0 top-full z-50 w-56 rounded border bg-background p-2 text-xs text-destructive">
    {error}
  </span>
{/if}
