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

async function openFilter() {
  await fireEvent.click(screen.getByTestId('chat-filter-trigger'));
  await tick();
}

test('ordinary users get an unchecked Archived checkbox without the deleted control', async () => {
  render(ChatList, { accountId: 'house' });
  await openFilter();
  expect(screen.getByRole('checkbox', { name: 'Archived' })).not.toBeChecked();
  expect(screen.queryByRole('checkbox', { name: 'Deleted' })).not.toBeInTheDocument();
});

test('Archived adds and removes only its own URL parameter', async () => {
  visit('/accounts/house/chats?room=all&show_deleted=true', { is_account_admin: true });
  render(ChatList, { accountId: 'house' });
  await openFilter();

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
  await openFilter();
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
    await openFilter();
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

test('Hidden and a tag each set only their own URL parameter, and links carry them', async () => {
  const visualTags = [
    { id: 'done', label: 'Done', icon: 'Checks', colour: 'green', hides_from_list: true },
    { id: 'work', label: 'Work', icon: 'Wrench', colour: 'blue' },
  ];
  visit('/accounts/house/chats?room=all', { visual_tags: visualTags });
  render(ChatList, { accountId: 'house', chats: [{ id: 'c1', title: 'One' }] });
  await openFilter();
  expect(screen.getByRole('checkbox', { name: 'Hidden' })).not.toBeChecked();

  await fireEvent.click(screen.getByRole('checkbox', { name: 'Hidden' }));
  let target = new URL(router.visit.mock.calls.at(-1)[0]);
  expect(Object.fromEntries(target.searchParams)).toEqual({ room: 'all', show_hidden: 'true' });

  await fireEvent.click(screen.getByRole('button', { name: /Work/ }));
  target = new URL(router.visit.mock.calls.at(-1)[0]);
  expect(Object.fromEntries(target.searchParams)).toEqual({ room: 'all', tag: 'work' });

  visit('/accounts/house/chats?room=all&show_hidden=true&tag=work', { visual_tags: visualTags });
  await tick();
  const link = new URL(screen.getByRole('link', { name: /One/ }).href);
  expect(link.searchParams.get('show_hidden')).toBe('true');
  expect(link.searchParams.get('tag')).toBe('work');

  await fireEvent.click(screen.getByRole('button', { name: 'Stop showing only Work' }));
  target = new URL(router.visit.mock.calls.at(-1)[0]);
  expect(Object.fromEntries(target.searchParams)).toEqual({ room: 'all', show_hidden: 'true' });
});

test('counts hidden conversations with an open red eye, and only those', async () => {
  visit('/accounts/house/chats', {
    hidden_chat_ids: ['h1', 'h2', 'h3'],
    reply_attention: { chats: { h1: 2, h3: 1, shown: 4 } },
  });
  render(ChatList, { accountId: 'house' });
  expect(screen.getByTestId('chat-filter-trigger')).toHaveAccessibleName(
    'Filter conversations, 2 hidden waiting on you'
  );
  await openFilter();
  expect(screen.getByTestId('hidden-attention-count')).toHaveTextContent('2');

  visit('/accounts/house/chats', { hidden_chat_ids: ['h2'], reply_attention: { chats: { h1: 2 } } });
  await tick();
  expect(screen.queryByTestId('hidden-attention-count')).not.toBeInTheDocument();
});

test('status and human-replied filters compose with room/tag/archive and survive links', async () => {
  visit('/accounts/house/chats?room=all&tag=work&show_archived=true&work_status=blocked&work_replied=true', {
    current_room: 'all',
    visual_tags: [{ id: 'work', label: 'Project', icon: 'Wrench', colour: 'blue' }],
  });
  render(ChatList, {
    accountId: 'house',
    chats: [
      {
        id: 'c1',
        title: 'One',
        work_status: { state: 'blocked', revision: 1, human_replied_since: '2026-11-11T20:00:00Z' },
      },
    ],
  });
  const link = new URL(screen.getByRole('link', { name: /One/ }).href);
  expect(Object.fromEntries(link.searchParams)).toEqual({
    room: 'all',
    tag: 'work',
    show_archived: 'true',
    work_status: 'blocked',
    work_replied: 'true',
  });
  await openFilter();
  expect(screen.getByLabelText('Work status', { exact: true })).toHaveValue('blocked');
  expect(screen.getByRole('checkbox', { name: 'Human replied since request or blocker' })).toBeChecked();
  await fireEvent.change(screen.getByLabelText('Work status', { exact: true }), { target: { value: 'idle' } });
  const target = new URL(router.visit.mock.calls.at(-1)[0]);
  expect(Object.fromEntries(target.searchParams)).toEqual({
    room: 'all',
    tag: 'work',
    show_archived: 'true',
    work_status: 'idle',
    work_replied: 'true',
  });
});

test('tracked rows replace tag icons, keep pin indicators and keep attention independent', async () => {
  visit('/accounts/house/chats', {
    reply_attention: { chats: { c1: 1 }, through_messages: { c1: 'm1' } },
  });
  render(ChatList, {
    accountId: 'house',
    chats: [
      {
        id: 'c1',
        title: 'One',
        visual_tag: { id: 'pin', label: 'Pin', icon: 'PushPin', colour: 'amber', pins_to_top: true },
        work_status: { state: 'ready_for_review', revision: 1 },
      },
    ],
  });
  expect(screen.queryByRole('button', { name: /Change visual tag/ })).not.toBeInTheDocument();
  expect(screen.getByRole('img', { name: 'Pinned by visual tag' })).toBeInTheDocument();
  expect(screen.getByTestId('work-status-summary')).toHaveTextContent('Ready for review');
  await fireEvent.click(screen.getByRole('button', { name: /You have a mention or request/ }));
  expect(router.post).toHaveBeenCalledWith(
    '/accounts/house/chats/c1/reply_dismissal',
    { through_message_id: 'm1' },
    expect.any(Object)
  );
  expect(screen.getByTestId('work-status-summary')).toHaveTextContent('Ready for review');
});
