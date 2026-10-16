import { describe, expect, test, vi } from 'vitest';
import { createRecordingGuard, LEAVE_WARNING } from './recording-guard';

function fakeRouter() {
  const listeners = new Set();
  return {
    reload: vi.fn(),
    on: vi.fn((type, callback) => {
      listeners.add(callback);
      return () => listeners.delete(callback);
    }),
    visit(visit) {
      const event = new CustomEvent('inertia:before', { cancelable: true, detail: { visit } });
      listeners.forEach((callback) => callback(event));
      return !event.defaultPrevented;
    },
    listenerCount: () => listeners.size,
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

    expect(router.listenerCount()).toBe(0);
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
    expect(router.listenerCount()).toBe(0);
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
