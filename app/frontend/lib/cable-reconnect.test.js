import { expect, test, vi } from 'vitest';
import { router, routerListeners } from '@inertiajs/svelte';
import { reloadProps, subscribeToModel } from './cable';

const { create } = vi.hoisted(() => ({ create: vi.fn(() => ({ unsubscribe: vi.fn() })) }));
vi.mock('@rails/actioncable', () => ({ createConsumer: () => ({ subscriptions: { create } }) }));

test('cross-account subscription counts catch up in one narrow reload on every reconnect', () => {
  vi.useFakeTimers();
  router.reload.mockClear();
  const cleanups = ['first', 'second'].map((id) =>
    subscribeToModel('Account', id, ['accounts', 'expired_subscriptions'])
  );
  const callbacks = create.mock.calls.slice(-2).map(([, callbacks]) => callbacks);
  for (let connection = 0; connection < 2; connection += 1) {
    router.reload.mockClear();
    callbacks.forEach((callback) => callback.connected());
    vi.advanceTimersByTime(300);
    expect(router.reload).toHaveBeenCalledOnce();
    expect(router.reload).toHaveBeenCalledWith(
      expect.objectContaining({
        only: ['accounts', 'expired_subscriptions'],
        preserveState: true,
        preserveScroll: true,
        preserveUrl: true,
      })
    );
  }
  cleanups.forEach((cleanup) => cleanup());
  vi.useRealTimers();
});

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

test('room navigation catches up on connect and reconnect using only its mapped props', () => {
  vi.useFakeTimers();
  router.reload.mockClear();
  const unsubscribe = subscribeToModel('RoomNavigation', 'account', ['rooms', 'current_room']);
  const callbacks = create.mock.calls.at(-1)[1];
  for (let connection = 0; connection < 2; connection += 1) {
    router.reload.mockClear();
    callbacks.connected();
    vi.advanceTimersByTime(300);
    expect(router.reload).toHaveBeenCalledOnce();
    expect(router.reload).toHaveBeenCalledWith(
      expect.objectContaining({
        only: ['rooms', 'current_room'],
        preserveState: true,
        preserveScroll: true,
        preserveUrl: true,
      })
    );
  }
  router.reload.mockClear();
  callbacks.received({ action: 'refresh' });
  vi.advanceTimersByTime(300);
  expect(router.reload).toHaveBeenCalledOnce();
  expect(router.reload).toHaveBeenCalledWith(expect.objectContaining({ only: ['rooms', 'current_room'] }));
  unsubscribe();
  vi.useRealTimers();
});

test.each(['RoomActivity', 'FieldActivity', 'RhythmActivity', 'IntegrationStatus'])(
  '%s catches up on connect and every reconnect',
  (model) => {
    vi.useFakeTimers();
    router.reload.mockClear();
    const unsubscribe = subscribeToModel(model, 'account', ['live_props']);
    const callbacks = create.mock.calls.at(-1)[1];
    // A run that finished while disconnected leaves no broadcast to replay.
    callbacks.connected();
    vi.advanceTimersByTime(300);
    expect(router.reload).toHaveBeenLastCalledWith(expect.objectContaining({ only: ['live_props'] }));
    router.reload.mockClear();
    callbacks.connected();
    vi.advanceTimersByTime(300);
    expect(router.reload).toHaveBeenCalledWith(expect.objectContaining({ only: ['live_props'] }));
    unsubscribe();
    router.reload.mockReset();
    vi.useRealTimers();
  }
);

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

// Field recordings: transcription finishes on the server and is broadcast once. A page that
// subscribes after that broadcast, or was disconnected when it went out, must still leave
// "Transcribing…" without a manual refresh. The catch-up is one reload per (re)connect.
test('a field recording that finished before the page subscribed is caught up on connect', () => {
  vi.useFakeTimers();
  router.reload.mockReset();
  const unsubscribe = subscribeToModel('FieldRecording', 'r1', ['recording', 'speakers']);
  const callbacks = create.mock.calls.at(-1)[1];
  expect(create.mock.calls.at(-1)[0]).toEqual({ channel: 'SyncChannel', model: 'FieldRecording', id: 'r1' });
  // No broadcast arrives (it went out before the subscription); connecting alone reloads.
  callbacks.connected();
  vi.advanceTimersByTime(300);
  expect(router.reload).toHaveBeenCalledOnce();
  expect(router.reload).toHaveBeenLastCalledWith(
    expect.objectContaining({ only: ['recording', 'speakers'], preserveState: true, preserveUrl: true })
  );
  unsubscribe();
  vi.useRealTimers();
});

test('a field recording that finished during a disconnect is caught up on reconnect, without polling', () => {
  vi.useFakeTimers();
  router.reload.mockReset();
  const unsubscribe = subscribeToModel('FieldRecording', 'r2', ['recording', 'speakers']);
  const callbacks = create.mock.calls.at(-1)[1];
  callbacks.connected();
  vi.advanceTimersByTime(300);
  router.reload.mockReset();

  callbacks.disconnected();
  // The completion broadcast is missed while disconnected; nothing reloads on a timer.
  vi.advanceTimersByTime(60_000);
  expect(router.reload).not.toHaveBeenCalled();

  callbacks.connected();
  vi.advanceTimersByTime(300);
  expect(router.reload).toHaveBeenCalledOnce();
  expect(router.reload).toHaveBeenLastCalledWith(expect.objectContaining({ only: ['recording', 'speakers'] }));
  router.reload.mockReset();
  vi.advanceTimersByTime(60_000);
  expect(router.reload).not.toHaveBeenCalled();
  unsubscribe();
  vi.useRealTimers();
});
