import { render, screen } from '@testing-library/svelte';
import { tick } from 'svelte';
import { writable } from 'svelte/store';
import { expect, test, vi } from 'vitest';

vi.mock('@inertiajs/svelte', async () => {
  const actual = await vi.importActual('@inertiajs/svelte');
  return { ...actual, page: writable({ props: {} }) };
});
const subscribe = vi.hoisted(() => vi.fn(() => vi.fn()));
vi.mock('$lib/cable', () => ({ subscribeToModel: subscribe }));
import { page } from '@inertiajs/svelte';
import Navbar from './navbar.svelte';

test('navbar watches all confirmed accounts, keeps stable subscriptions and removes lost access', async () => {
  const props = {
    user: { id: 'me', email_address: 'me@example.com' },
    account: { id: 'one', name: 'First' },
    accounts: [
      { id: 'two', name: 'Second' },
      { id: 'one', name: 'First' },
    ],
    expired_subscriptions: { total: 0, accounts: {}, items: [] },
  };
  page.set({ props });
  const component = render(Navbar);
  await tick();
  const accountCalls = () => subscribe.mock.calls.filter(([model]) => model === 'Account');
  expect(accountCalls()).toEqual([
    ['Account', 'two', ['accounts', 'expired_subscriptions']],
    ['Account', 'one', ['accounts', 'expired_subscriptions', 'account', 'is_account_admin']],
  ]);
  expect(subscribe).toHaveBeenCalledWith('ReplyAttention', 'me', [
    'reply_attention',
    'accounts',
    'expired_subscriptions',
  ]);
  const initialAccountUnsubscribers = subscribe.mock.calls.flatMap(([model], index) =>
    model === 'Account' ? [subscribe.mock.results[index].value] : []
  );
  page.set({
    props: { ...props, account: { ...props.account, name: 'Renamed' }, accounts: [...props.accounts].reverse() },
  });
  await tick();
  expect(screen.getByRole('link', { name: 'Renamed' })).toHaveAttribute('href', '/');
  expect(accountCalls()).toHaveLength(2);
  for (const unsubscribe of initialAccountUnsubscribers) expect(unsubscribe).not.toHaveBeenCalled();

  page.set({ props: { ...props, account: props.accounts[0] } });
  await tick();
  for (const unsubscribe of initialAccountUnsubscribers) expect(unsubscribe).toHaveBeenCalledOnce();
  expect(accountCalls().slice(-2)).toEqual([
    ['Account', 'two', ['accounts', 'expired_subscriptions', 'account', 'is_account_admin']],
    ['Account', 'one', ['accounts', 'expired_subscriptions']],
  ]);

  page.set({ props: { ...props, accounts: [props.accounts[1]] } });
  await tick();
  for (const unsubscribe of initialAccountUnsubscribers) expect(unsubscribe).toHaveBeenCalledOnce();
  expect(accountCalls().at(-1)).toEqual([
    'Account',
    'one',
    ['accounts', 'expired_subscriptions', 'account', 'is_account_admin'],
  ]);
  const lastAccountIndex = subscribe.mock.calls.findLastIndex(([model]) => model === 'Account');
  const last = subscribe.mock.results[lastAccountIndex].value;
  page.set({ props: {} });
  await tick();
  expect(last).toHaveBeenCalledOnce();
  component.unmount();
});

test('navbar does not create a current-account channel when it is absent from confirmed accounts', async () => {
  page.set({
    props: {
      user: { id: 'me' },
      account: { id: 'not-listed', name: 'Not listed' },
      accounts: [{ id: 'other', name: 'Other' }],
    },
  });
  render(Navbar);
  await tick();
  expect(subscribe.mock.calls.filter(([model]) => model === 'Account')).toEqual([
    ['Account', 'other', ['accounts', 'expired_subscriptions']],
  ]);
  expect(subscribe).toHaveBeenCalledWith('ReplyAttention', 'me', [
    'reply_attention',
    'accounts',
    'expired_subscriptions',
  ]);
});

test('room navigation watches only the active account, even empty, without resubscribing on reload', async () => {
  const props = {
    user: { id: 'me', email_address: 'me@example.com' },
    account: { id: 'one', name: 'First' },
    accounts: [{ id: 'one' }, { id: 'two' }],
    rooms: [],
    current_room: 'main',
  };
  page.set({ props });
  const component = render(Navbar);
  await tick();
  const roomCalls = () => subscribe.mock.calls.filter(([model]) => model === 'RoomNavigation');
  expect(roomCalls()).toEqual([['RoomNavigation', 'one', ['rooms', 'current_room', 'main_room_name']]]);
  const firstIndex = subscribe.mock.calls.findIndex(([model]) => model === 'RoomNavigation');
  const firstCleanup = subscribe.mock.results[firstIndex].value;

  page.set({ props: { ...props, rooms: [{ id: 'life', name: 'Life' }] } });
  await tick();
  expect(roomCalls()).toHaveLength(1);
  expect(firstCleanup).not.toHaveBeenCalled();

  page.set({ props: { ...props, account: { id: 'two', name: 'Second' } } });
  await tick();
  expect(firstCleanup).toHaveBeenCalledOnce();
  expect(roomCalls()).toEqual([
    ['RoomNavigation', 'one', ['rooms', 'current_room', 'main_room_name']],
    ['RoomNavigation', 'two', ['rooms', 'current_room', 'main_room_name']],
  ]);
  const secondIndex = subscribe.mock.calls.findLastIndex(([model]) => model === 'RoomNavigation');
  const secondCleanup = subscribe.mock.results[secondIndex].value;
  page.set({ props: {} });
  await tick();
  expect(secondCleanup).toHaveBeenCalledOnce();
  expect(roomCalls()).toHaveLength(2);

  page.set({ props });
  await tick();
  const finalIndex = subscribe.mock.calls.findLastIndex(([model]) => model === 'RoomNavigation');
  const finalCleanup = subscribe.mock.results[finalIndex].value;
  component.unmount();
  expect(finalCleanup).toHaveBeenCalledOnce();
});
