import { render } from '@testing-library/svelte';
import { afterEach, expect, test, vi } from 'vitest';
import Harness from '../test/provider-subscription-harness.svelte';

const agent = { id: 'synthetic', name: 'Synthetic', provider: 'anthropic', available: false };
afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

test('closing during sign-in startup does not restart polling after the late response', async () => {
  vi.useFakeTimers();
  let finishStart;
  vi.stubGlobal(
    'fetch',
    vi.fn((url) => {
      if (url.endsWith('/cancel')) return Promise.resolve({ ok: true, json: async () => ({}) });
      return new Promise((resolve) => (finishStart = resolve));
    })
  );
  const view = render(Harness, { agent });
  const state = view.component.subscription;
  const starting = state.beginConnection();
  await state.cancelConnection();
  expect(state.connectOpen).toBe(false);
  finishStart({ ok: true, json: async () => ({ status: 'pending', user_code: 'synthetic-code' }) });
  await starting;
  const requests = fetch.mock.calls.length;
  await vi.advanceTimersByTimeAsync(10000);
  expect(fetch).toHaveBeenCalledTimes(requests);
  expect(state.ceremony).toBe(null);
  view.unmount();
});

test('unmount aborts pending subscription requests', async () => {
  let finish;
  vi.stubGlobal(
    'fetch',
    vi.fn(() => new Promise((resolve) => (finish = resolve)))
  );
  const view = render(Harness, { agent });
  const pending = view.component.subscription.beginConnection();
  const signal = fetch.mock.calls[0][1].signal;
  view.unmount();
  expect(signal.aborted).toBe(true);
  finish({ ok: true, json: async () => ({ status: 'pending' }) });
  await pending;
});
