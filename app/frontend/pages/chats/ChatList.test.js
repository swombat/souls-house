import { fireEvent, render, screen } from '@testing-library/svelte';
import { page, router } from '@inertiajs/svelte';
import { tick } from 'svelte';
import { beforeEach, expect, test, vi } from 'vitest';
import ChatList from './ChatList.svelte';

vi.mock('@inertiajs/svelte', async (importOriginal) => {
  const original = await importOriginal();
  const { writable } = await import('svelte/store');
  return { ...original, page: writable({ url: '/', props: {} }) };
});
vi.mock('$lib/use-sync', () => ({ createDynamicSync: () => () => {} }));

function visit(url, props = {}) {
  window.history.replaceState({}, '', url);
  page.set({ url, props });
}

beforeEach(() => visit('/accounts/house/chats'));

test('ordinary users get an unchecked Archived checkbox without the deleted control', () => {
  render(ChatList, { accountId: 'house' });
  expect(screen.getByRole('checkbox', { name: 'Archived' })).not.toBeChecked();
  expect(screen.queryByRole('checkbox', { name: 'Deleted' })).not.toBeInTheDocument();
});

test('Archived adds and removes only its own URL parameter', async () => {
  visit('/accounts/house/chats?room=all&show_deleted=true', { is_account_admin: true });
  render(ChatList, { accountId: 'house' });

  await fireEvent.click(screen.getByRole('checkbox', { name: 'Archived' }));
  let target = new URL(router.visit.mock.calls.at(-1)[0]);
  expect(target.pathname).toBe('/accounts/house/chats');
  expect(Object.fromEntries(target.searchParams)).toEqual({
    room: 'all',
    show_deleted: 'true',
    show_archived: 'true',
  });
  expect(router.visit).toHaveBeenLastCalledWith(target.toString(), { preserveState: true });

  visit(target.pathname + target.search, { is_account_admin: true });
  await tick();
  expect(screen.getByRole('checkbox', { name: 'Archived' })).toBeChecked();
  await fireEvent.click(screen.getByRole('checkbox', { name: 'Archived' }));
  target = new URL(router.visit.mock.calls.at(-1)[0]);
  expect(Object.fromEntries(target.searchParams)).toEqual({ room: 'all', show_deleted: 'true' });
});

test('checkbox follows navigation and history URLs while the sidebar stays mounted', async () => {
  visit('/accounts/house/chats?show_archived=true');
  render(ChatList, { accountId: 'house' });
  expect(screen.getByRole('checkbox', { name: 'Archived' })).toBeChecked();

  visit('/accounts/house/chats?show_archived=false');
  await tick();
  expect(screen.getByRole('checkbox', { name: 'Archived' })).not.toBeChecked();

  visit('/accounts/house/chats?show_archived=true');
  await tick();
  expect(screen.getByRole('checkbox', { name: 'Archived' })).toBeChecked();
});

test.each([undefined, 'all'])(
  'conversation links carry the archived filter with current room %s',
  async (currentRoom) => {
    visit('/accounts/house/chats?show_archived=true', { current_room: currentRoom });
    render(ChatList, { accountId: 'house', chats: [{ id: 'old', title: 'Old conversation', archived: true }] });
    let target = new URL(screen.getByRole('link', { name: /Old conversation/ }).href);
    expect(target.pathname).toBe('/accounts/house/chats/old');
    expect(target.searchParams.get('show_archived')).toBe('true');
    expect(target.searchParams.get('room')).toBe(currentRoom || null);

    visit('/accounts/house/chats', { current_room: currentRoom });
    await tick();
    target = new URL(screen.getByRole('link', { name: /Old conversation/ }).href);
    expect(target.searchParams.has('show_archived')).toBe(false);
    expect(target.searchParams.get('room')).toBe(currentRoom || null);
  }
);

test.each([{ is_account_admin: true }, { user: { site_admin: true } }])(
  'existing deleted permissions and toggle preserve the archived filter: %j',
  async (props) => {
    visit('/accounts/house/chats?room=all&show_archived=true', props);
    render(ChatList, { accountId: 'house' });
    expect(screen.getByRole('checkbox', { name: 'Archived' })).toBeChecked();
    expect(screen.getByRole('checkbox', { name: 'Deleted' })).not.toBeChecked();

    await fireEvent.click(screen.getByRole('checkbox', { name: 'Deleted' }));
    const target = new URL(router.visit.mock.calls.at(-1)[0]);
    expect(Object.fromEntries(target.searchParams)).toEqual({
      room: 'all',
      show_archived: 'true',
      show_deleted: 'true',
    });
  }
);
