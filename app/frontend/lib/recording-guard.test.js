import { describe, expect, test, vi } from 'vitest';
import axios from 'axios';
import { createRecordingGuard, LEAVE_WARNING } from './recording-guard';

function fakeRouter() {
  const listeners = { before: new Set(), finish: new Set() };
  return {
    reload: vi.fn(),
    on: vi.fn((type, callback) => {
      listeners[type]?.add(callback);
      return () => listeners[type]?.delete(callback);
    }),
    visit(visit) {
      const event = new CustomEvent('inertia:before', { cancelable: true, detail: { visit } });
      listeners.before.forEach((callback) => callback(event));
      return !event.defaultPrevented;
    },
    finish(visit) {
      const event = new CustomEvent('inertia:finish', { detail: { visit } });
      listeners.finish.forEach((callback) => callback(event));
    },
  };
}

function fakeWindow(confirmAnswer = false) {
  const target = new EventTarget();
  return {
    addEventListener: vi.fn((...args) => target.addEventListener(...args)),
    removeEventListener: vi.fn((...args) => target.removeEventListener(...args)),
    confirm: vi.fn(() => confirmAnswer),
    unload() {
      const event = new Event('beforeunload', { cancelable: true });
      target.dispatchEvent(event);
      return event.defaultPrevented;
    },
  };
}

const reload = (only = []) => ({ method: 'get', async: true, only });

describe('recording guard', () => {
  test('leaves visits alone when nothing is recording', () => {
    const router = fakeRouter();
    const win = fakeWindow();
    createRecordingGuard({ router, win });

    expect(router.visit(reload(['messages']))).toBe(true);
    expect(win.unload()).toBe(false);
  });

  test('holds background reloads while recording and reloads their props afterwards', () => {
    const router = fakeRouter();
    const guard = createRecordingGuard({ router, win: fakeWindow() });

    const release = guard.hold();
    expect(router.visit(reload(['messages']))).toBe(false);
    expect(router.visit(reload(['chat', 'messages']))).toBe(false);
    expect(router.reload).not.toHaveBeenCalled();

    release();
    expect(router.reload).toHaveBeenCalledTimes(1);
    expect(router.reload.mock.calls[0][0]).toMatchObject({ only: ['messages', 'chat'], preserveUrl: true });
    expect(router.visit(reload(['messages']))).toBe(true);
  });

  test('a held full reload is replayed as a full reload, and a prefetch is simply dropped', () => {
    const router = fakeRouter();
    const guard = createRecordingGuard({ router, win: fakeWindow() });

    const release = guard.hold();
    expect(router.visit({ method: 'get', async: true, prefetch: true, only: [] })).toBe(false);
    release();
    expect(router.reload).not.toHaveBeenCalled();

    const again = guard.hold();
    router.visit(reload(['messages']));
    router.visit(reload());
    again();
    expect(router.reload.mock.calls[0][0].only).toBeUndefined();
  });

  test('does not hold async writes', () => {
    const router = fakeRouter();
    const guard = createRecordingGuard({ router, win: fakeWindow() });
    guard.hold();

    expect(router.visit({ method: 'post', async: true, only: [] })).toBe(true);
  });

  test('asks before a visit or an unload would discard the recording', () => {
    const router = fakeRouter();
    const win = fakeWindow(false);
    const guard = createRecordingGuard({ router, win });

    const release = guard.hold();
    expect(router.visit({ method: 'get', async: false })).toBe(false);
    expect(win.confirm).toHaveBeenCalledWith(LEAVE_WARNING);
    expect(win.unload()).toBe(true);

    win.confirm.mockReturnValue(true);
    expect(router.visit({ method: 'get', async: false })).toBe(true);

    release();
    expect(win.unload()).toBe(false);
  });

  test('a quiet hold holds refreshes without asking, and holds nest', () => {
    const router = fakeRouter();
    const win = fakeWindow(false);
    const guard = createRecordingGuard({ router, win });

    const recording = guard.hold();
    const sending = guard.hold({ warn: false });
    recording();
    recording();

    expect(guard.isHeld()).toBe(true);
    expect(router.visit({ method: 'get', async: false })).toBe(true);
    expect(win.confirm).not.toHaveBeenCalled();
    expect(win.unload()).toBe(false);
    expect(router.visit(reload(['messages']))).toBe(false);
    expect(router.reload).not.toHaveBeenCalled();

    sending();
    expect(guard.isHeld()).toBe(false);
    expect(router.reload).toHaveBeenCalledTimes(1);
  });
});

describe('responses already in flight', () => {
  function fakeHttp() {
    let onRejected;
    return {
      interceptors: { response: { use: (_ok, rejected) => (onRejected = rejected) } },
      fail: (error) => onRejected(error),
    };
  }
  const conflict = (partial, method = 'get') => ({
    response: { status: 409, headers: { 'x-inertia-location': '/accounts/1/chats/2' } },
    config: { method, headers: partial ? { 'X-Inertia-Partial-Data': partial } : {} },
  });

  test('a version conflict that lands during a hold becomes a cancellation and is replayed', async () => {
    const router = fakeRouter();
    const http = fakeHttp();
    const guard = createRecordingGuard({ router, http, win: fakeWindow() });

    const release = guard.hold();
    const error = await http.fail(conflict('messages,chat')).catch((rejection) => rejection);
    expect(axios.isCancel(error)).toBe(true);

    release();
    expect(router.reload.mock.calls[0][0].only).toEqual(['messages', 'chat']);
  });

  test('outside a hold, and for other errors, responses pass through untouched', async () => {
    const http = fakeHttp();
    const guard = createRecordingGuard({ router: fakeRouter(), http, win: fakeWindow() });

    const outside = conflict('messages');
    await expect(http.fail(outside)).rejects.toBe(outside);

    guard.hold();
    const serverError = { response: { status: 500, headers: {} }, config: {} };
    await expect(http.fail(serverError)).rejects.toBe(serverError);
  });

  test('a redirected POST (a new conversation being created) passes through untouched', async () => {
    const router = fakeRouter();
    const http = fakeHttp();
    const guard = createRecordingGuard({ router, http, win: fakeWindow() });

    const release = guard.hold({ warn: false });
    const created = conflict(null, 'post');
    await expect(http.fail(created)).rejects.toBe(created);

    release();
    expect(router.reload).not.toHaveBeenCalled();
  });

  test('a visit the person confirmed passes through; background refreshes are caught again after it', async () => {
    const router = fakeRouter();
    const http = fakeHttp();
    const guard = createRecordingGuard({ router, http, win: fakeWindow(true) });

    guard.hold();
    const visit = { method: 'get', async: false };
    expect(router.visit(visit)).toBe(true);
    const leaving = conflict(null);
    await expect(http.fail(leaving)).rejects.toBe(leaving);

    router.finish(visit);
    const background = await http.fail(conflict('messages')).catch((rejection) => rejection);
    expect(axios.isCancel(background)).toBe(true);
  });

  test('a declined visit does not let later 409s through', async () => {
    const http = fakeHttp();
    const router = fakeRouter();
    const guard = createRecordingGuard({ router, http, win: fakeWindow(false) });

    guard.hold();
    expect(router.visit({ method: 'get', async: false })).toBe(false);
    const background = await http.fail(conflict('messages')).catch((rejection) => rejection);
    expect(axios.isCancel(background)).toBe(true);
  });
});
