<script>
  import { page } from '@inertiajs/svelte';
  import { CaretDown } from 'phosphor-svelte';
  import * as DropdownMenu from '$lib/components/shadcn/dropdown-menu/index.js';
  import { buttonVariants } from '$lib/components/shadcn/button/index.js';
  import { cn } from '$lib/utils.js';
  import { views, visitRoom, waitingIn, ALL } from '$lib/rooms';

  // The navbar's Chats entry once an account has rooms. Activity elsewhere is
  // shown inside the menu only, never on the closed trigger.
  let { accountId, label = 'Chats' } = $props();

  const rooms = $derived($page.props.rooms || []);
  const current = $derived($page.props.current_room || 'main');
  const attention = $derived($page.props.reply_attention);
</script>

<DropdownMenu.Root>
  <DropdownMenu.Trigger
    data-testid="nav-chat-rooms"
    class={cn(buttonVariants({ variant: 'ghost' }), 'rounded-full text-muted-foreground gap-1')}>
    {label}
    <CaretDown size={12} />
  </DropdownMenu.Trigger>
  <DropdownMenu.Content align="start" class="w-52">
    {#each views(rooms) as option (option.id)}
      {@const waiting = option.id === ALL ? 0 : waitingIn(option.id, attention)}
      {#if option.id === ALL}
        <DropdownMenu.Separator />
      {/if}
      <DropdownMenu.Item onclick={() => visitRoom(accountId, option.id)} class="justify-between gap-3">
        <span class="truncate {option.id === current ? 'font-semibold' : ''}">{option.name}</span>
        {#if waiting > 0}
          <span
            class="rounded-full bg-primary px-1.5 text-[10px] font-semibold leading-4 text-primary-foreground"
            title="{waiting} waiting on you">{waiting}</span>
        {/if}
      </DropdownMenu.Item>
    {/each}
  </DropdownMenu.Content>
</DropdownMenu.Root>
