import { describe, expect, test, vi } from 'vitest';
import { createWakeLock, watchPage } from './voice-mode-lifecycle';

function fakeLocks() {
  const locks = [];
  const nav = {
    wakeLock: {
      request: vi.fn(async () => {
        const lock = {
          listeners: [],
          release: vi.fn(async () => {}),
          addEventListener: (type, fn) => lock.listeners.push(fn),
          drop: () => lock.listeners.forEach((fn) => fn()),
        };
        locks.push(lock);
        return lock;
      }),
    },
  };
  return { nav, locks };
}

describe('createWakeLock', () => {
  test('holds the screen while wanted, asks again after the browser drops it, and lets go on release', async () => {
    const { nav, locks } = fakeLocks();
    const doc = { visibilityState: 'visible' };
    const wake = createWakeLock({ nav, doc });
    expect(await wake.acquire()).toBe(true);
    expect(wake.held).toBe(true);
    expect(await wake.acquire()).toBe(true);
    expect(nav.wakeLock.request).toHaveBeenCalledTimes(1);

    // Hidden: the browser releases it; not asked for while hidden.
    doc.visibilityState = 'hidden';
    locks[0].drop();
    expect(wake.held).toBe(false);
    expect(await wake.reacquire()).toBe(false);

    doc.visibilityState = 'visible';
    expect(await wake.reacquire()).toBe(true);
    expect(nav.wakeLock.request).toHaveBeenCalledTimes(2);

    await wake.release();
    expect(locks[1].release).toHaveBeenCalled();
    expect(await wake.reacquire()).toBe(false);
  });

  test('is a quiet no-op without the API or when refused', async () => {
    expect(await createWakeLock({ nav: {}, doc: { visibilityState: 'visible' } }).acquire()).toBe(false);
    const nav = { wakeLock: { request: vi.fn(async () => Promise.reject(new Error('NotAllowedError'))) } };
    expect(await createWakeLock({ nav, doc: { visibilityState: 'visible' } }).acquire()).toBe(false);
  });
});

describe('watchPage', () => {
  test('reports hidden, visible, pagehide and online, and stops when asked', () => {
    const doc = new EventTarget();
    const win = new EventTarget();
    const seen = [];
    const stop = watchPage({
      doc,
      win,
      onhidden: () => seen.push('hidden'),
      onvisible: () => seen.push('visible'),
      onpagehide: () => seen.push('pagehide'),
      ononline: () => seen.push('online'),
    });
    doc.visibilityState = 'hidden';
    doc.dispatchEvent(new Event('visibilitychange'));
    win.dispatchEvent(new Event('pagehide'));
    doc.visibilityState = 'visible';
    doc.dispatchEvent(new Event('visibilitychange'));
    win.dispatchEvent(new Event('online'));
    stop();
    win.dispatchEvent(new Event('online'));
    expect(seen).toEqual(['hidden', 'pagehide', 'visible', 'online']);
  });
});
