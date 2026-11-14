import { fireEvent, render, screen, within } from '@testing-library/svelte';
import { tick } from 'svelte';
import { writable } from 'svelte/store';
import { vi } from 'vitest';

vi.mock('@inertiajs/svelte', async (importOriginal) => ({
  ...(await importOriginal()),
  page: writable({ props: {} }),
}));

import { page, router } from '@inertiajs/svelte';
import NewChatForm from './NewChatForm.svelte';

const pageProps = {
  errors: {},
  flash: {},
  rooms: [{ id: 'work', name: 'Work' }],
  main_room_name: 'Home',
  current_room: 'main',
};

const props = {
  userId: 'user',
  account: { id: 'account' },
  agents: [{ id: 'resident', name: 'Resident' }],
};
const originalScrollIntoView = HTMLElement.prototype.scrollIntoView;

beforeEach(() => {
  localStorage.clear();
  page.set({ props: pageProps, url: '/' });
  vi.spyOn(router, 'visit').mockImplementation(() => {});
  vi.spyOn(router, 'post').mockImplementation(() => {});
  // jsdom has no scrolling API; the select scrolls its highlighted option.
  HTMLElement.prototype.scrollIntoView = vi.fn();
});
afterEach(() => {
  vi.restoreAllMocks();
  if (originalScrollIntoView) HTMLElement.prototype.scrollIntoView = originalScrollIntoView;
  else delete HTMLElement.prototype.scrollIntoView;
});

test('the room selector sits in the title row, not on a row of its own', () => {
  render(NewChatForm, props);
  const header = screen.getByTitle('Edit chat title').closest('header');
  const trigger = within(header).getByTestId('new-chat-room');
  expect(trigger).toHaveTextContent('Home');
  expect(trigger.parentElement).toHaveClass('md:hidden');
  expect(screen.getAllByTestId('new-chat-room')).toHaveLength(1);
});

test.each([
  ['Work', 'work'],
  ['All chats', 'all'],
])('choosing %s navigates the active room rather than changing a local destination', async (name, key) => {
  render(NewChatForm, props);
  await fireEvent.keyDown(screen.getByTestId('new-chat-room'), { key: 'Enter' });
  await fireEvent.pointerUp(screen.getByRole('option', { name }));
  expect(router.visit).toHaveBeenCalledExactlyOnceWith(`/accounts/account/chats?room=${key}`);
  expect(router.post).not.toHaveBeenCalled();
});

test('the selector follows active room updates, including All chats and renamed Main', async () => {
  render(NewChatForm, props);
  for (const [key, label] of [
    ['work', 'Work'],
    ['all', 'All chats'],
    ['main', 'Home'],
  ]) {
    page.set({ props: { ...pageProps, current_room: key }, url: '/' });
    await tick();
    expect(screen.getByTestId('new-chat-room')).toHaveTextContent(label);
  }
});

test.each([
  ['work', 'work'],
  ['main', ''],
  ['all', ''],
])('creation uses the current room %s after a same-page update', async (currentRoom, expectedRoomId) => {
  // No independent creation-room selection: desktop and mobile share this form.
  page.set({ props: { ...pageProps, current_room: currentRoom === 'work' ? 'main' : 'work' }, url: '/' });
  render(NewChatForm, props);
  page.set({ props: { ...pageProps, current_room: currentRoom }, url: '/' });
  await tick();
  await fireEvent.input(screen.getByRole('textbox'), { target: { value: 'hello' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Start conversation' }));
  expect(router.post).toHaveBeenCalledTimes(1);
  expect(router.post.mock.calls[0][1].get('room_id')).toBe(expectedRoomId);
});

test('the mobile selector is absent for an account without rooms', () => {
  page.set({ props: { ...pageProps, rooms: [] }, url: '/' });
  render(NewChatForm, props);
  expect(screen.queryByTestId('new-chat-room')).toBeNull();
});

test('the routine draft note is desktop-only; nothing about it shows on a phone', () => {
  render(NewChatForm, props);
  const note = screen.getByText(/Draft saved only in this browser/).parentElement;
  expect(note).toHaveClass('hidden', 'md:block');
});

test('in an archived room the composer says so and starts the conversation in Main', async () => {
  page.set({
    props: {
      ...pageProps,
      rooms: [...pageProps.rooms, { id: 'old', name: 'Application', archived: true }],
      current_room: 'old',
    },
    url: '/',
  });
  render(NewChatForm, props);
  expect(screen.getByTestId('archived-room-note')).toHaveTextContent('Application is archived');
  expect(screen.getByTestId('archived-room-note')).toHaveTextContent('begins in Home');
});
