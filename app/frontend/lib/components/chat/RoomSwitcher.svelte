<script>
  import { page, router } from '@inertiajs/svelte';
  import { Check } from 'phosphor-svelte';
  import * as Select from '$lib/components/shadcn/select/index.js';
  import RoomWorkingSpinner from './RoomWorkingSpinner.svelte';
  import { views, roomName, roomsPath, visitRoom, waitingIn, workingIn, ALL } from '$lib/rooms';

  // The sidebar's room switcher. It shows the same selection as the navbar's
  // Chats menu: one navigation state, stored on the server per account.
  // With a mouse, resting on the room name lists the rooms, no click needed
  // (the same gesture as the navbar's account switcher). Touch and keyboard
  // keep the select: tap, or focus and press Enter.
  let { accountId } = $props();

  const rooms = $derived($page.props.rooms || []);
  const current = $derived($page.props.current_room || 'main');
  const attention = $derived($page.props.reply_attention);
  const activity = $derived($page.props.room_activity);

  const CLOSE_DELAY_MS = 200;
  let hoverOpen = $state(false);
  let closeTimer = null;

  function cancelClose() {
    clearTimeout(closeTimer);
    closeTimer = null;
  }

  function show(event) {
    if (event.pointerType !== 'mouse') return;
    cancelClose();
    hoverOpen = true;
  }

  function hide(event) {
    if (event.pointerType !== 'mouse') return;
    cancelClose();
    closeTimer = setTimeout(() => (hoverOpen = false), CLOSE_DELAY_MS);
  }

  function closeNow() {
    cancelClose();
    hoverOpen = false;
  }

  // The panel is already showing, so a mouse click on the name would only open
  // the select on top of it. Stop it before it reaches the trigger.
  function swallowWhileOpen(event) {
    if (hoverOpen && event.pointerType === 'mouse') event.stopPropagation();
  }

  // Plain anchors so middle-click and cmd-click still open a new tab.
  function visit(event, key) {
    closeNow();
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    if (key !== current) router.visit(roomsPath(accountId, key));
  }

  $effect(() => () => clearTimeout(closeTimer));
</script>

{#snippet badges(key)}
  {@const waiting = key === ALL ? 0 : waitingIn(key, attention)}
  <span class="flex shrink-0 items-center gap-1.5">
    <RoomWorkingSpinner agents={workingIn(key, activity)} />
    {#if waiting > 0}
      <span
        class="rounded-full bg-primary px-1.5 text-[10px] font-semibold leading-4 text-primary-foreground"
        title="{waiting} waiting on you">{waiting}</span>
    {/if}
  </span>
{/snippet}

<svelte:window onkeydown={(event) => event.key === 'Escape' && closeNow()} />

<div
  class="relative min-w-0"
  role="presentation"
  data-testid="room-hover-switcher"
  onpointerenter={show}
  onpointerleave={hide}
  onpointerdowncapture={swallowWhileOpen}>
  <Select.Root type="single" value={current} onValueChange={(key) => key !== current && visitRoom(accountId, key)}>
    <Select.Trigger
      data-testid="room-switcher"
      aria-label="Room"
      class="h-8 w-auto max-w-56 gap-2 border-0 bg-transparent px-1 text-lg font-semibold shadow-none">
      <span class="truncate">{roomName(current, rooms)}</span>
    </Select.Trigger>
    <Select.Content sideOffset={4}>
      {#each views(rooms) as option (option.id)}
        <Select.Item value={option.id} label={option.name}>
          <span class="flex w-full items-center justify-between gap-3">
            <span class="truncate">{option.name}</span>
            {@render badges(option.id)}
          </span>
        </Select.Item>
      {/each}
    </Select.Content>
  </Select.Root>
  {#if hoverOpen}
    <!-- pt-1 bridges the gap under the name so the pointer can travel into the list without it closing. -->
    <div class="absolute left-0 top-full z-50 pt-1" data-testid="room-hover-switcher-panel">
      <div class="w-56 max-w-[80vw] rounded-md border bg-popover p-1 text-popover-foreground shadow-md">
        {#each views(rooms) as option (option.id)}
          {@const selected = option.id === current}
          <a
            href={roomsPath(accountId, option.id)}
            onclick={(event) => visit(event, option.id)}
            aria-current={selected ? 'page' : undefined}
            class="flex items-center gap-2 rounded-sm px-2 py-1.5 text-sm outline-none hover:bg-accent hover:text-accent-foreground focus-visible:bg-accent {selected
              ? 'font-semibold'
              : ''}">
            <Check class="size-4 shrink-0 {selected ? 'opacity-100' : 'opacity-0'}" />
            <span class="min-w-0 truncate">{option.name}</span>
            <span class="ml-auto">{@render badges(option.id)}</span>
          </a>
        {/each}
      </div>
    </div>
  {/if}
</div>
