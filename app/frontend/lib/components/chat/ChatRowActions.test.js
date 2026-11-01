import { fireEvent, render, screen } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import { expect, test } from 'vitest';
import ChatRowActions from './ChatRowActions.svelte';
import ChatSidebarItem from './ChatSidebarItem.svelte';

const chat = { id: 'chat-one', title: 'A question', visual_tag: null, room_id: null };
const rooms = [{ id: 'room-two', name: 'Work' }];
const open = () => fireEvent.click(screen.getByRole('button', { name: /^Actions for / }));

test('the hover menu is there even with no rooms, outside the link, desktop only', () => {
  render(ChatSidebarItem, { chat, accountId: 'house', rooms: [] });
  const button = screen.getByRole('button', { name: 'Actions for A question' });
  expect(button.closest('a')).toBeNull();
  // Desktop only: hidden below md, where the conversation menu does this.
  expect(button.closest('[data-row-actions]')).toHaveClass('hidden', 'md:inline-flex');
});

test('Archive posts to the archive route', async () => {
  render(ChatRowActions, { chat, accountId: 'house', rooms: [] });
  await open();
  await fireEvent.click(await screen.findByRole('menuitem', { name: 'Archive' }));
  expect(router.post).toHaveBeenLastCalledWith(
    '/accounts/house/chats/chat-one/archive',
    {},
    expect.objectContaining({ preserveScroll: true })
  );
});

test('an archived conversation offers Unarchive', async () => {
  render(ChatRowActions, { chat: { ...chat, archived: true }, accountId: 'house', rooms: [] });
  await open();
  await fireEvent.click(await screen.findByRole('menuitem', { name: 'Unarchive' }));
  expect(router.delete).toHaveBeenLastCalledWith(
    '/accounts/house/chats/chat-one/archive',
    expect.objectContaining({ preserveScroll: true })
  );
});

test('with no other room there is no Move to room section', async () => {
  render(ChatRowActions, { chat, accountId: 'house', rooms: [] });
  await open();
  await screen.findByRole('menuitem', { name: 'Archive' });
  expect(screen.queryByText('Move to room')).toBeNull();
});

test('moving sends the chosen room, and Main as null', async () => {
  render(ChatRowActions, { chat, accountId: 'house', rooms });
  await open();
  await fireEvent.click(await screen.findByRole('menuitem', { name: 'Work' }));
  expect(router.patch).toHaveBeenLastCalledWith(
    '/accounts/house/chats/chat-one/room',
    { room_id: 'room-two' },
    expect.objectContaining({ preserveScroll: true, preserveState: true })
  );
});

test('the current room is marked and cannot be chosen', async () => {
  render(ChatRowActions, { chat: { ...chat, room_id: 'room-two' }, accountId: 'house', rooms });
  await open();
  expect(await screen.findByRole('menuitem', { name: 'Work' })).toHaveAttribute('data-disabled');
  await fireEvent.click(screen.getByRole('menuitem', { name: 'Main' }));
  expect(router.patch.mock.calls.at(-1)[1]).toEqual({ room_id: null });
});

test('a failed move is reported', async () => {
  render(ChatRowActions, { chat, accountId: 'house', rooms });
  await open();
  await fireEvent.click(await screen.findByRole('menuitem', { name: 'Work' }));
  router.patch.mock.calls.at(-1)[2].onError();
  expect(await screen.findByRole('alert')).toHaveTextContent('Could not move this conversation');
});
