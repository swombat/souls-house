import { expect, test, vi } from 'vitest';
import { router } from '@inertiajs/svelte';
import { subscribeToModel } from './cable';

const { create } = vi.hoisted(() => ({ create: vi.fn(() => ({ unsubscribe: vi.fn() })) }));
vi.mock('@rails/actioncable', () => ({ createConsumer: () => ({ subscriptions: { create } }) }));

test('account sidebar catches up on connect/reconnect and receives lifecycle broadcasts', () => {
  vi.useFakeTimers();
  const unsubscribe = subscribeToModel('Account', 'account', ['chats']);
  const callbacks = create.mock.calls.at(-1)[1];
  callbacks.connected();
  vi.advanceTimersByTime(300);
  expect(router.reload).toHaveBeenLastCalledWith({ only: ['chats'], preserveState: true, preserveScroll: true });
  router.reload.mockClear();
  callbacks.received({ action: 'refresh', prop: 'chats' });
  vi.advanceTimersByTime(300);
  expect(router.reload).toHaveBeenCalledOnce();
  unsubscribe();
  expect(create.mock.results.at(-1).value.unsubscribe).toHaveBeenCalledOnce();
  vi.useRealTimers();
});
