import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import { pinConversationEntry } from './chat-entry-scroll';

let container, resized, observer, height;
beforeEach(() => {
  vi.useFakeTimers();
  height = 2000;
  container = document.createElement('div');
  container.append(document.createElement('div'));
  Object.defineProperties(container, {
    scrollHeight: { get: () => height },
    clientHeight: { value: 500 },
  });
  container.scrollTo = vi.fn(({ top }) => {
    container.scrollTop = Math.max(0, top - 500);
  });
  observer = { observe: vi.fn(), disconnect: vi.fn() };
  vi.stubGlobal(
    'ResizeObserver',
    vi.fn(function (callback) {
      resized = callback;
      return observer;
    })
  );
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

test('snaps instantly, follows late content/viewport layout, and ignores its own scroll event', () => {
  const release = pinConversationEntry(container);
  expect(container.scrollTo).toHaveBeenLastCalledWith({ top: 2000, behavior: 'instant' });
  expect(observer.observe).toHaveBeenCalledWith(container.firstElementChild, { box: 'border-box' });
  expect(observer.observe).toHaveBeenCalledWith(container);
  container.dispatchEvent(new Event('scroll'));
  height = 3000;
  resized();
  expect(container.scrollTop).toBe(2500);
  release();
});

test.each(['wheel', 'touchstart', 'pointerdown', 'keydown', 'scroll'])('reader %s releases the entry pin', (event) => {
  pinConversationEntry(container);
  if (event === 'scroll') container.scrollTop = 100;
  container.dispatchEvent(new Event(event));
  height = 3000;
  resized();
  expect(container.scrollTo).toHaveBeenCalledTimes(1);
  expect(observer.disconnect).toHaveBeenCalled();
});

test('the pin expires and explicit cleanup prevents queued observer callbacks', () => {
  const release = pinConversationEntry(container);
  vi.advanceTimersByTime(2000);
  resized();
  expect(container.scrollTo).toHaveBeenCalledTimes(1);
  release();
  expect(vi.getTimerCount()).toBe(0);
});

test('another bottom-following scroll does not release later layout following', () => {
  const release = pinConversationEntry(container);
  height = 2500;
  container.scrollTop = 2000;
  container.dispatchEvent(new Event('scroll'));
  height = 3000;
  resized();
  expect(container.scrollTop).toBe(2500);
  release();
});
