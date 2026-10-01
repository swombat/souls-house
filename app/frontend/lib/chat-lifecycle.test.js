import { tick } from 'svelte';
import { render, screen } from '@testing-library/svelte';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import { router } from '@inertiajs/svelte';
import Harness from '../test/chat-lifecycle-harness.svelte';

const message = (id, content = id) => ({ id, content, role: 'user' });
beforeEach(() => {
  vi.stubGlobal('fetch', vi.fn());
  HTMLElement.prototype.scrollTo = vi.fn();
});
afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

test('a late history response cannot enter another conversation', async () => {
  let resolve;
  fetch.mockImplementation(() => new Promise((done) => (resolve = done)));
  const view = render(Harness, { chat: { id: 'first' }, messages: [message('first-recent')] });
  const pending = view.component.history.loadMore();
  expect(fetch).toHaveBeenCalledTimes(1);
  const signal = fetch.mock.calls[0][1].signal;
  await view.rerender({ chat: { id: 'second' }, messages: [message('second-recent')] });
  expect(signal.aborted).toBe(true);
  resolve({ ok: true, json: async () => ({ messages: [message('first-older')], has_more: false }) });
  await pending;
  expect(screen.getByText('second-recent')).toBeInTheDocument();
  expect(screen.queryByText('first-older')).not.toBeInTheDocument();
  expect(view.component.history.loading).toBe(false);
});

test('a recent-window reload retains displaced rows, without resurrecting deleted rows', async () => {
  fetch.mockResolvedValue({
    ok: true,
    json: async () => ({
      messages: [message('older')],
      has_more: false,
      oldest_id: 'older',
    }),
  });
  const view = render(Harness, { chat: { id: 'chat' }, messages: [message('recent')] });
  await view.component.history.loadMore();
  await view.rerender({ chat: { id: 'chat' }, messages: [message('newest')] });
  expect(screen.getByText('older')).toBeInTheDocument();
  expect(screen.getByText('recent')).toBeInTheDocument();
  view.component.history.remove('recent');
  await view.rerender({ chat: { id: 'chat' }, messages: [message('newest'), message('latest')] });
  expect(screen.queryByText('recent')).not.toBeInTheDocument();
  expect(screen.getByText('older')).toBeInTheDocument();
});

test('fallback reads and group prompts are cancelled on chat change and unmount', async () => {
  vi.useFakeTimers();
  const view = render(Harness, { chat: { id: 'first', manual_responses: true } });
  view.component.response.refreshMessages();
  view.component.response.prompt();
  await view.rerender({ chat: { id: 'second', manual_responses: true } });
  expect(view.component.response.agentPrompt).toBe(false);
  await vi.advanceTimersByTimeAsync(6000);
  expect(router.reload).not.toHaveBeenCalled();
  view.component.response.refreshMessages();
  view.unmount();
  await vi.advanceTimersByTimeAsync(6000);
  expect(router.reload).not.toHaveBeenCalled();
});

test('unmount aborts an outstanding history request', async () => {
  let resolve;
  fetch.mockImplementation(() => new Promise((done) => (resolve = done)));
  const view = render(Harness, { chat: { id: 'chat' }, messages: [message('recent')] });
  const pending = view.component.history.loadMore();
  const signal = fetch.mock.calls[0][1].signal;
  view.unmount();
  expect(signal.aborted).toBe(true);
  resolve({ ok: true, json: async () => ({ messages: [], has_more: false }) });
  await pending;
});

test('entry snaps without paginating, including reused-page navigation', async () => {
  const view = render(Harness, { chat: { id: 'first' }, messages: [message('first')] });
  await tick();
  expect(HTMLElement.prototype.scrollTo).toHaveBeenLastCalledWith({ top: 0, behavior: 'instant' });
  const element = view.component.history.container;
  Object.defineProperties(element, {
    scrollHeight: { configurable: true, value: 5000 },
    clientHeight: { configurable: true, value: 500 },
  });
  element.scrollTo = vi.fn(({ top, behavior }) => {
    // Model the opening scroll events: smooth animation starts near the top.
    element.scrollTop = behavior === 'smooth' ? 10 : top - element.clientHeight;
    element.dispatchEvent(new Event('scroll'));
  });
  await view.rerender({ chat: { id: 'second' }, messages: [message('second')] });
  expect(element.scrollTo).toHaveBeenLastCalledWith({ top: 5000, behavior: 'instant' });
  expect(fetch).not.toHaveBeenCalled();
  element.dispatchEvent(new Event('wheel'));
  element.scrollTop = 1000;
  element.scrollTo.mockClear();
  await view.rerender({ chat: { id: 'second' }, messages: [message('second'), message('new')] });
  expect(element.scrollTo).not.toHaveBeenCalled();
  expect(element.scrollTop).toBe(1000);
  // Explicit sending retains its separate scroll behavior.
  fetch.mockResolvedValue({ ok: true, json: async () => ({ messages: [], has_more: false }) });
  view.component.history.scrollToBottom();
  await tick();
  expect(element.scrollTo).toHaveBeenLastCalledWith({ top: 5000, behavior: 'smooth' });
});
