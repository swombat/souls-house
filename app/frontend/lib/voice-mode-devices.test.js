import { expect, test, vi } from 'vitest';
import { watchDevices } from './voice-mode-devices';

test('a burst of device changes is reported once, after it settles; stop removes the listener', () => {
  vi.useFakeTimers();
  const listeners = new Set();
  const mediaDevices = {
    addEventListener: (type, fn) => listeners.add(fn),
    removeEventListener: (type, fn) => listeners.delete(fn),
  };
  const onchange = vi.fn();
  const stop = watchDevices({ mediaDevices, onchange, settleMs: 800 });
  listeners.forEach((fn) => fn());
  vi.advanceTimersByTime(500);
  listeners.forEach((fn) => fn());
  vi.advanceTimersByTime(700);
  expect(onchange).not.toHaveBeenCalled();
  vi.advanceTimersByTime(200);
  expect(onchange).toHaveBeenCalledTimes(1);
  stop();
  expect(listeners.size).toBe(0);
  vi.useRealTimers();
});

test('a browser without device events is left alone', () => {
  expect(() => watchDevices({ mediaDevices: undefined, onchange: () => {} })()).not.toThrow();
});
