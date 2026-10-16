import { render } from '@testing-library/svelte';
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
    ['Account', 'one', ['accounts', 'expired_subscriptions']],
  ]);
  expect(subscribe).toHaveBeenCalledWith('ReplyAttention', 'me', [
    'reply_attention',
    'accounts',
    'expired_subscriptions',
  ]);
  const initialAccountUnsubscribers = subscribe.mock.results.slice(-2).map(({ value }) => value);
  page.set({
    props: { ...props, account: props.accounts[0], accounts: [...props.accounts].reverse() },
  });
  await tick();
  expect(accountCalls()).toHaveLength(2);
  for (const unsubscribe of initialAccountUnsubscribers) expect(unsubscribe).not.toHaveBeenCalled();

  page.set({ props: { ...props, accounts: [props.accounts[1]] } });
  await tick();
  for (const unsubscribe of initialAccountUnsubscribers) expect(unsubscribe).toHaveBeenCalledOnce();
  expect(accountCalls().at(-1)).toEqual(['Account', 'one', ['accounts', 'expired_subscriptions']]);
  const last = subscribe.mock.results.at(-1).value;
  page.set({ props: {} });
  await tick();
  expect(last).toHaveBeenCalledOnce();
  component.unmount();
});
