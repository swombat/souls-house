import { render, screen, fireEvent } from '@testing-library/svelte';
import { writable } from 'svelte/store';
import { beforeEach, expect, test, vi } from 'vitest';

const visit = vi.hoisted(() => vi.fn());
vi.mock('@inertiajs/svelte', async () => {
  const actual = await vi.importActual('@inertiajs/svelte');
  return { ...actual, page: writable({ props: {} }), router: { ...actual.router, visit } };
});
import { page } from '@inertiajs/svelte';
import ChatRoomsNavMenu from './ChatRoomsNavMenu.svelte';
import { getNextMatch } from '../../../../../node_modules/bits-ui/dist/internal/arrays.js';

beforeEach(() => {
  visit.mockClear();
  page.set({
    props: {
      rooms: [
        { id: 'r1', name: 'Workshop' },
        { id: 'r2', name: 'Garage' },
      ],
      current_room: 'main',
      reply_attention: { rooms: {} },
      room_activity: {},
      room_chat_counts: { rooms: { main: 4, r1: 3, r2: 12 }, all: 19 },
    },
  });
});

async function open() {
  render(ChatRoomsNavMenu, { accountId: 'acc' });
  await fireEvent.click(screen.getByTestId('nav-chat-rooms'));
  await screen.findAllByRole('menuitem');
}

test('with totals on, each item still begins with the room name, the count shown first only by CSS order', async () => {
  await open();
  const items = screen.getAllByRole('menuitem').filter((item) => item.dataset.testid !== 'manage-rooms');
  // Menu typeahead matches the start of the item's text, so the name leads.
  expect(items.map((item) => item.textContent.replace(/\s+/g, ' ').trim())).toEqual([
    'Main 4',
    'Workshop 3',
    'Garage 12',
    'All chats 19',
  ]);
  const count = items[1].querySelector('[data-testid="room-chat-count"]');
  expect(count.className).toContain('order-first');
  expect(count.className).toContain('text-muted-foreground');
});

// The menu's own typeahead matcher (Bits UI DOMTypeahead) on the rendered
// items' text: typing a room's first letters still finds it with totals on.
// With the count first in the DOM ("12Garage"), nothing would match.
test('typing a room name finds it with totals on', async () => {
  await open();
  const values = screen.getAllByRole('menuitem').map((item) => item.textContent?.trim() ?? '');
  expect(getNextMatch(values, 'g', values[0])).toMatch(/^Garage/);
  expect(getNextMatch(values, 'wo', values[0])).toMatch(/^Workshop/);
  expect(getNextMatch(['12Garage'], 'g', '')).toBeUndefined();
});
