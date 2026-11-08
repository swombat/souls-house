import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';
import { flushSync } from 'svelte';

const cable = vi.hoisted(() => ({ performed: [], callbacks: null }));
vi.mock('$lib/cable', () => ({
  cableConsumer: () => ({
    subscriptions: {
      create: (_params, callbacks) => {
        cable.callbacks = callbacks;
        queueMicrotask(() => callbacks.connected());
        return { perform: (_action, data) => cable.performed.push(data.state), unsubscribe: () => {} };
      },
    },
  }),
}));

import TypingIndicator from './TypingIndicator.svelte';

beforeEach(() => {
  vi.useFakeTimers();
  cable.performed = [];
});
afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

async function mount(props) {
  const result = render(TypingIndicator, { chatId: 'c1', userId: 'me', ...props });
  await Promise.resolve();
  return result;
}

test('a restored draft is not typing; a change is, and emptying the box is a stop', async () => {
  const { rerender } = await mount({ content: 'left over from yesterday' });
  expect(cable.performed).toEqual([]);

  await rerender({ content: 'left over from yesterday!' });
  await rerender({ content: '' });
  expect(cable.performed).toEqual(['typing', 'idle']);
});

test('dictating keeps announcing until it ends, then stops', async () => {
  const { rerender } = await mount({ content: '' });
  await rerender({ dictating: true });
  vi.advanceTimersByTime(3100);
  await rerender({ dictating: false });
  expect(cable.performed).toEqual(['dictating', 'dictating', 'idle']);
  vi.advanceTimersByTime(10_000);
  expect(cable.performed).toHaveLength(3);
});

test("shows someone else's typing above the box", async () => {
  await mount({ content: '' });
  cable.callbacks.received({ user_id: 'anna', name: 'Anna', state: 'typing' });
  flushSync();
  expect(screen.getByTestId('typing-indicator').textContent).toContain('Anna is typing…');
});

test('leaving mid-sentence sends a stop', async () => {
  const { rerender, unmount } = await mount({ content: '' });
  await rerender({ content: 'hel' });
  unmount();
  expect(cable.performed).toEqual(['typing', 'idle']);
});
