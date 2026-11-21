import { render, screen, fireEvent } from '@testing-library/svelte';
import { tick } from 'svelte';
import { writable } from 'svelte/store';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';

const visit = vi.hoisted(() => vi.fn());
vi.mock('@inertiajs/svelte', async () => {
  const actual = await vi.importActual('@inertiajs/svelte');
  return { ...actual, page: writable({ props: {} }), router: { ...actual.router, visit } };
});
import { page } from '@inertiajs/svelte';
import RoomSwitcher from './RoomSwitcher.svelte';

beforeEach(() => {
  visit.mockClear();
  page.set({
    props: {
      rooms: [{ id: 'r1', name: 'Studio' }],
      current_room: 'main',
      reply_attention: { rooms: { r1: 2 } },
      room_activity: {},
    },
  });
});
afterEach(() => vi.useRealTimers());

function setup() {
  render(RoomSwitcher, { accountId: 'acc' });
  return screen.getByTestId('room-hover-switcher');
}

// jsdom has no PointerEvent, so give a plain event the pointerType the browser would.
async function pointer(element, type, pointerType, init = {}) {
  const event = new Event(type, { bubbles: true, cancelable: true });
  Object.defineProperty(event, 'pointerType', { value: pointerType });
  Object.defineProperty(event, 'button', { value: init.button ?? 0 });
  Object.defineProperty(event, 'ctrlKey', { value: false });
  Object.defineProperty(event, 'pointerId', { value: 1 });
  await fireEvent(element, event);
}

test('resting the mouse on the room name lists every room, the current one marked', async () => {
  const wrapper = setup();
  expect(screen.queryByTestId('room-hover-switcher-panel')).toBeNull();
  await pointer(wrapper, 'pointerenter', 'mouse');
  const links = screen.getByTestId('room-hover-switcher-panel').querySelectorAll('a');
  expect([...links].map((a) => a.getAttribute('href'))).toEqual([
    '/accounts/acc/chats?room=main',
    '/accounts/acc/chats?room=r1',
    '/accounts/acc/chats?room=all',
  ]);
  expect(links[0]).toHaveAttribute('aria-current', 'page');
  expect(links[1]).toHaveTextContent('Studio');
  expect(links[1]).toHaveTextContent('2');
  await fireEvent.click(links[1]);
  expect(visit).toHaveBeenCalledWith('/accounts/acc/chats?room=r1');
  expect(screen.queryByTestId('room-hover-switcher-panel')).toBeNull();
});

test('touch does not open it; the tap still goes to the select', async () => {
  const wrapper = setup();
  await pointer(wrapper, 'pointerenter', 'touch');
  expect(screen.queryByTestId('room-hover-switcher-panel')).toBeNull();
});

// The click-while-open guard needs a real browser: playwright/tests/rooms.pw.js.

test('it closes shortly after the mouse leaves, and stays open if the mouse comes back', async () => {
  vi.useFakeTimers();
  const wrapper = setup();
  await pointer(wrapper, 'pointerenter', 'mouse');
  await pointer(wrapper, 'pointerleave', 'mouse');
  vi.advanceTimersByTime(100);
  await pointer(wrapper, 'pointerenter', 'mouse');
  vi.advanceTimersByTime(500);
  await tick();
  expect(screen.getByTestId('room-hover-switcher-panel')).toBeTruthy();
  await pointer(wrapper, 'pointerleave', 'mouse');
  vi.advanceTimersByTime(250);
  await tick();
  expect(screen.queryByTestId('room-hover-switcher-panel')).toBeNull();
});

test('Escape closes it', async () => {
  const wrapper = setup();
  await pointer(wrapper, 'pointerenter', 'mouse');
  await fireEvent.keyDown(window, { key: 'Escape' });
  expect(screen.queryByTestId('room-hover-switcher-panel')).toBeNull();
});

test('with the account switch off, no room shows a total', async () => {
  const wrapper = setup();
  await pointer(wrapper, 'pointerenter', 'mouse');
  expect(screen.queryAllByTestId('room-chat-count')).toEqual([]);
});

test('with the account switch on, each room shows its total, faint, to the left of its name', async () => {
  page.update((p) => ({ ...p, props: { ...p.props, room_chat_counts: { rooms: { main: 4, r1: 12 }, all: 16 } } }));
  const wrapper = setup();
  await pointer(wrapper, 'pointerenter', 'mouse');
  const links = screen.getByTestId('room-hover-switcher-panel').querySelectorAll('a');
  const totals = [...links].map((a) => a.querySelector('[data-testid="room-chat-count"]').textContent);
  expect(totals).toEqual(['4', '12', '16']);
  const studio = links[1];
  const count = studio.querySelector('[data-testid="room-chat-count"]');
  const name = [...studio.querySelectorAll('span')].find((span) => span.textContent === 'Studio');
  expect(count.compareDocumentPosition(name) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  expect(count.className).toContain('text-muted-foreground');
  // The waiting badge is unchanged beside it.
  expect(studio.querySelector('[title="2 waiting on you"]')).not.toBeNull();
});

test('a room with nothing in it shows 0 rather than nothing', async () => {
  page.update((p) => ({ ...p, props: { ...p.props, room_chat_counts: { rooms: { main: 3 }, all: 3 } } }));
  const wrapper = setup();
  await pointer(wrapper, 'pointerenter', 'mouse');
  const links = screen.getByTestId('room-hover-switcher-panel').querySelectorAll('a');
  expect(links[1].querySelector('[data-testid="room-chat-count"]').textContent).toBe('0');
});
