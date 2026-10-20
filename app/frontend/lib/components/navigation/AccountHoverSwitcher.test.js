import { render, screen, fireEvent } from '@testing-library/svelte';
import { createRawSnippet, tick } from 'svelte';
import { afterEach, expect, test, vi } from 'vitest';
import AccountHoverSwitcher from './AccountHoverSwitcher.svelte';

const accounts = [
  { id: 'one', name: 'First' },
  { id: 'two', name: 'Second' },
];
const children = createRawSnippet(() => ({ render: () => '<a href="/accounts/one/chats">First</a>' }));

function setup(props = {}) {
  render(AccountHoverSwitcher, { currentAccount: accounts[0], accounts, children, ...props });
  return screen.getByTestId('nav-account-switcher');
}

// jsdom has no PointerEvent, so give a plain event the pointerType the browser would.
async function pointer(element, type, pointerType) {
  const event = new Event(type);
  Object.defineProperty(event, 'pointerType', { value: pointerType });
  await fireEvent(element, event);
}

afterEach(() => vi.useRealTimers());

test('resting the mouse on the account name lists every account, the current one marked', async () => {
  const wrapper = setup({ replyAttention: { accounts: { two: 3 } } });
  expect(screen.queryByTestId('nav-account-switcher-panel')).toBeNull();
  await pointer(wrapper, 'pointerenter', 'mouse');
  const panel = screen.getByTestId('nav-account-switcher-panel');
  const links = panel.querySelectorAll('a');
  expect([...links].map((a) => a.getAttribute('href'))).toEqual(['/accounts/one/chats', '/accounts/two/chats']);
  expect(links[0]).toHaveAttribute('aria-current', 'page');
  expect(links[1]).not.toHaveAttribute('aria-current');
  expect(links[1]).toHaveTextContent('3');
  await fireEvent.click(links[1]);
  expect(screen.queryByTestId('nav-account-switcher-panel')).toBeNull();
});

test('touch does not open it; switching on a phone stays in the user account menu', async () => {
  const wrapper = setup();
  await pointer(wrapper, 'pointerenter', 'touch');
  expect(screen.queryByTestId('nav-account-switcher-panel')).toBeNull();
});

test('someone with one account gets no panel', async () => {
  const wrapper = setup({ accounts: [accounts[0]] });
  await pointer(wrapper, 'pointerenter', 'mouse');
  expect(screen.queryByTestId('nav-account-switcher-panel')).toBeNull();
});

test('it closes shortly after the mouse leaves, and stays open if the mouse comes back', async () => {
  vi.useFakeTimers();
  const wrapper = setup();
  await pointer(wrapper, 'pointerenter', 'mouse');
  await pointer(wrapper, 'pointerleave', 'mouse');
  vi.advanceTimersByTime(100);
  await pointer(wrapper, 'pointerenter', 'mouse');
  vi.advanceTimersByTime(500);
  await tick();
  expect(screen.getByTestId('nav-account-switcher-panel')).toBeTruthy();
  await pointer(wrapper, 'pointerleave', 'mouse');
  vi.advanceTimersByTime(250);
  await tick();
  expect(screen.queryByTestId('nav-account-switcher-panel')).toBeNull();
});

test('Escape closes it', async () => {
  const wrapper = setup();
  await pointer(wrapper, 'pointerenter', 'mouse');
  await fireEvent.keyDown(window, { key: 'Escape' });
  expect(screen.queryByTestId('nav-account-switcher-panel')).toBeNull();
});
