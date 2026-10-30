import { afterEach, beforeEach, expect, test, vi } from 'vitest';

vi.mock('$lib/cable', () => ({ reloadProps: vi.fn() }));

import { reloadProps } from '$lib/cable';
import { visibleRefresh } from './visible-refresh';

let visibility = 'visible';

beforeEach(() => {
  vi.useFakeTimers();
  reloadProps.mockClear();
  visibility = 'visible';
  vi.spyOn(document, 'visibilityState', 'get').mockImplementation(() => visibility);
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

function setVisibility(state) {
  visibility = state;
  document.dispatchEvent(new Event('visibilitychange'));
}

test('reloads only the given props every interval while the page is visible', () => {
  const cleanup = visibleRefresh(['active_sessions'], 60_000);
  vi.advanceTimersByTime(59_999);
  expect(reloadProps).not.toHaveBeenCalled();
  vi.advanceTimersByTime(1);
  expect(reloadProps).toHaveBeenCalledTimes(1);
  expect(reloadProps).toHaveBeenLastCalledWith(['active_sessions']);
  vi.advanceTimersByTime(60_000);
  expect(reloadProps).toHaveBeenCalledTimes(2);
  cleanup();
});

test('does not poll while hidden, and reloads at once on becoming visible', () => {
  const cleanup = visibleRefresh(['active_sessions', 'active_session_totals'], 60_000);
  setVisibility('hidden');
  expect(reloadProps).not.toHaveBeenCalled();
  vi.advanceTimersByTime(180_000);
  expect(reloadProps).not.toHaveBeenCalled();

  setVisibility('visible');
  expect(reloadProps).toHaveBeenCalledTimes(1);
  expect(reloadProps).toHaveBeenLastCalledWith(['active_sessions', 'active_session_totals']);
  cleanup();
});

test('cleanup stops both the timer and the visibility listener', () => {
  const cleanup = visibleRefresh(['active_sessions'], 60_000);
  cleanup();
  vi.advanceTimersByTime(300_000);
  setVisibility('hidden');
  setVisibility('visible');
  expect(reloadProps).not.toHaveBeenCalled();
  expect(vi.getTimerCount()).toBe(0);
});
