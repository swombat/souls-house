import { render, screen, within } from '@testing-library/svelte';
import { readable } from 'svelte/store';
import { vi } from 'vitest';

vi.mock('@inertiajs/svelte', async (importOriginal) => ({
  ...(await importOriginal()),
  page: readable({
    props: { errors: {}, flash: {}, rooms: [{ id: 'work', name: 'Work' }], main_room_name: 'Main', current_room: 'main' },
    url: '/',
  }),
}));

import NewChatForm from './NewChatForm.svelte';

const props = {
  userId: 'user',
  account: { id: 'account' },
  agents: [{ id: 'resident', name: 'Resident' }],
};

beforeEach(() => localStorage.clear());

test('the room selector sits in the title row, not on a row of its own', () => {
  render(NewChatForm, props);
  const header = screen.getByTitle('Edit chat title').closest('header');
  expect(within(header).getByTestId('new-chat-room')).toHaveTextContent('Main');
  expect(screen.getAllByTestId('new-chat-room')).toHaveLength(1);
});

test('the routine draft note is desktop-only; nothing about it shows on a phone', () => {
  render(NewChatForm, props);
  const note = screen.getByText(/Draft saved only in this browser/).parentElement;
  expect(note).toHaveClass('hidden', 'md:block');
});
