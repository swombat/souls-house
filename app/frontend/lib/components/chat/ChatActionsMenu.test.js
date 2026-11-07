import { fireEvent, render, screen } from '@testing-library/svelte';
import { expect, test, vi } from 'vitest';
import { writable } from 'svelte/store';
import ChatActionsMenu from './ChatActionsMenu.svelte';

vi.mock('@inertiajs/svelte', () => ({ page: writable({ props: { main_room_name: 'Main' } }) }));

const chat = { id: 'c1', manual_responses: true, room_id: null };
const rooms = [{ id: 'r1', name: 'Music' }];

async function open() {
  await fireEvent.pointerDown(screen.getByRole('button', { name: 'Conversation actions' }), { button: 0 });
  await fireEvent.click(screen.getByRole('button', { name: 'Conversation actions' }));
}

test('offers Manage residents instead of Add Resident', async () => {
  const onManageResidents = vi.fn();
  render(ChatActionsMenu, {
    chat,
    agents: [{ id: 'a', name: 'Mira', can_remove_from_chat: true }],
    addableAgents: [],
    onManageResidents,
  });
  await open();
  expect(screen.queryByRole('menuitem', { name: 'Add Resident' })).toBeNull();
  await fireEvent.click(await screen.findByRole('menuitem', { name: 'Manage residents' }));
  expect(onManageResidents).toHaveBeenCalled();
});

test('Move to room drills down in place and Back returns', async () => {
  const onMoveToRoom = vi.fn();
  render(ChatActionsMenu, { chat, rooms, onMoveToRoom });
  await open();
  await fireEvent.click(await screen.findByRole('menuitem', { name: /Move to room/ }));
  expect(await screen.findByRole('menuitem', { name: 'Back' })).toBeInTheDocument();
  expect(screen.queryByRole('menuitem', { name: /Archive/ })).toBeNull();
  await fireEvent.click(screen.getByRole('menuitem', { name: 'Music' }));
  expect(onMoveToRoom).toHaveBeenCalledWith('r1');
});
