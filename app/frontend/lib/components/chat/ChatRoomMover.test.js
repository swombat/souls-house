import { fireEvent, render, screen } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import { expect, test } from 'vitest';
import ChatRoomMover from './ChatRoomMover.svelte';
import ChatSidebarItem from './ChatSidebarItem.svelte';

const chat = { id: 'chat-one', title: 'A question', visual_tag: null, room_id: null };
const rooms = [{ id: 'room-two', name: 'Work' }];

test('the hover mover appears only when the account has another room, outside the link', () => {
  const { container, unmount } = render(ChatSidebarItem, { chat, accountId: 'house', rooms: [] });
  expect(container.querySelector('[data-room-mover]')).toBeNull();
  unmount();

  render(ChatSidebarItem, { chat, accountId: 'house', rooms });
  const button = screen.getByRole('button', { name: 'Move to room' });
  expect(button.closest('a')).toBeNull();
  // Desktop only: hidden below md, where the conversation menu does this.
  expect(button.closest('[data-room-mover]')).toHaveClass('hidden', 'md:inline-flex');
});

test('moving sends the chosen room, and Main as null', async () => {
  render(ChatRoomMover, { chat, accountId: 'house', rooms });
  await fireEvent.click(screen.getByRole('button', { name: 'Move to room' }));
  await fireEvent.click(await screen.findByRole('menuitem', { name: 'Work' }));
  expect(router.patch).toHaveBeenLastCalledWith(
    '/accounts/house/chats/chat-one/room',
    { room_id: 'room-two' },
    expect.objectContaining({ preserveScroll: true, preserveState: true })
  );
});

test('the current room is marked and cannot be chosen', async () => {
  render(ChatRoomMover, { chat: { ...chat, room_id: 'room-two' }, accountId: 'house', rooms });
  await fireEvent.click(screen.getByRole('button', { name: 'Move to room' }));
  expect(await screen.findByRole('menuitem', { name: 'Work' })).toHaveAttribute('data-disabled');
  await fireEvent.click(screen.getByRole('menuitem', { name: 'Main' }));
  expect(router.patch.mock.calls.at(-1)[1]).toEqual({ room_id: null });
});

test('a failed move is reported', async () => {
  render(ChatRoomMover, { chat, accountId: 'house', rooms });
  await fireEvent.click(screen.getByRole('button', { name: 'Move to room' }));
  await fireEvent.click(await screen.findByRole('menuitem', { name: 'Work' }));
  router.patch.mock.calls.at(-1)[2].onError();
  expect(await screen.findByRole('alert')).toHaveTextContent('Could not move this conversation');
});
