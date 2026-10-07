import { expect, test, vi } from 'vitest';
import { router, routerListeners } from '@inertiajs/svelte';
import { reloadProps, subscribeToModel } from './cable';

const { create } = vi.hoisted(() => ({ create: vi.fn(() => ({ unsubscribe: vi.fn() })) }));
vi.mock('@rails/actioncable', () => ({ createConsumer: () => ({ subscriptions: { create } }) }));

test('account sidebar catches up on connect/reconnect and receives lifecycle broadcasts', () => {
  vi.useFakeTimers();
  const unsubscribe = subscribeToModel('Account', 'account', ['chats']);
  const callbacks = create.mock.calls.at(-1)[1];
  callbacks.connected();
  vi.advanceTimersByTime(300);
  expect(router.reload).toHaveBeenLastCalledWith(
    expect.objectContaining({ only: ['chats'], preserveState: true, preserveScroll: true, preserveUrl: true })
  );
  router.reload.mockClear();
  callbacks.received({ action: 'refresh', prop: 'chats' });
  vi.advanceTimersByTime(300);
  expect(router.reload).toHaveBeenCalledOnce();
  unsubscribe();
  expect(create.mock.results.at(-1).value.unsubscribe).toHaveBeenCalledOnce();
  vi.useRealTimers();
});

test('a navigation cancels an in-flight background refresh and re-queues it against the new page', () => {
  vi.useFakeTimers();
  const cancel = vi.fn();
  router.reload.mockImplementation((options) => {
    options.onCancelToken({ cancel });
    cancel.mockImplementation(() => options.onCancel());
  });
  reloadProps(['accounts']);
  vi.advanceTimersByTime(300);
  expect(router.reload).toHaveBeenCalledOnce();

  const fireBefore = (async) =>
    routerListeners.before.forEach((listener) => listener({ detail: { visit: { async } } }));
  fireBefore(true);
  expect(cancel).not.toHaveBeenCalled();
  fireBefore(false);
  expect(cancel).toHaveBeenCalledOnce();

  router.reload.mockReset();
  vi.advanceTimersByTime(300);
  expect(router.reload).toHaveBeenCalledWith(expect.objectContaining({ only: ['accounts'], preserveUrl: true }));
  vi.useRealTimers();
});

test('a refresh requested while a visit is in flight waits for the visit to finish', () => {
  vi.useFakeTimers();
  router.reload.mockReset();
  const fire = (type, async) => routerListeners[type].forEach((listener) => listener({ detail: { visit: { async } } }));
  fire('start', false);
  reloadProps(['selected_account']);
  vi.advanceTimersByTime(300);
  expect(router.reload).not.toHaveBeenCalled();
  fire('finish', false);
  vi.advanceTimersByTime(300);
  expect(router.reload).toHaveBeenCalledWith(expect.objectContaining({ only: ['selected_account'] }));
  vi.useRealTimers();
});
