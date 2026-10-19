import { render, screen, cleanup, fireEvent, waitFor } from '@testing-library/svelte';
import { afterEach, expect, test, vi } from 'vitest';
import { tick } from 'svelte';
import { router } from '@inertiajs/svelte';
import Summary from './AgentSubscriptionUsageSummary.svelte';

vi.mock('@inertiajs/svelte', () => ({ router: { reload: vi.fn() } }));

const subscription = {
  available: true,
  provider: 'anthropic',
  auth_mode: 'oauth_account',
  connection: { status: 'connected' },
};
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

test('keeps both quota bars visible at a limit, showing used rather than remaining', async () => {
  vi.stubGlobal(
    'fetch',
    vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        status: 'limited',
        windows: [
          { label: 'Session', remaining_percent: 0, resets_at: new Date(Date.now() + 2.5 * 3600000).toISOString() },
          { label: 'Weekly', remaining_percent: 60, resets_at: new Date(Date.now() + 3.5 * 86400000).toISOString() },
        ],
      }),
    })
  );
  render(Summary, { accountId: 'a', agentId: 'b', modelId: '', subscription });
  expect(await screen.findByText('Subscription limit reached')).toBeVisible();
  expect(screen.getAllByRole('meter')).toHaveLength(2);
  expect(screen.getByText('100% used')).toBeVisible();
  expect(screen.getByText('200% predicted')).toHaveClass('text-red-600');
  expect(screen.getByText('80% predicted')).toHaveClass('text-amber-700');
  expect(screen.getByText('Shared subscription')).toBeVisible();
});

test('does not fetch or imply zero usage for disconnected subscriptions', async () => {
  const fetch = vi.fn();
  vi.stubGlobal('fetch', fetch);
  render(Summary, { accountId: 'a', agentId: 'b', modelId: '', subscription: { ...subscription, connection: {} } });
  expect(await screen.findByText('Subscription not connected')).toBeVisible();
  expect(fetch).not.toHaveBeenCalled();
  expect(screen.queryByRole('meter')).not.toBeInTheDocument();
});

test('uses an explicit admin usage endpoint instead of account membership routes', async () => {
  const fetchUsage = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ status: 'available', windows: [] }) });
  vi.stubGlobal('fetch', fetchUsage);
  render(Summary, {
    accountId: 'a',
    agentId: 'b',
    modelId: '',
    subscription,
    usageUrl: '/admin/agents/b/provider_subscription_usage',
  });
  expect(await screen.findByText('Usage unavailable')).toBeVisible();
  expect(fetchUsage).toHaveBeenCalledWith('/admin/agents/b/provider_subscription_usage', expect.any(Object));
});

test('does not refetch or hide usage when live updates replace equivalent subscription props', async () => {
  const fetchUsage = vi.fn().mockResolvedValue({
    ok: true,
    json: async () => ({
      status: 'available',
      windows: [{ label: 'Weekly', remaining_percent: 60, resets_at: new Date(Date.now() + 86400000).toISOString() }],
    }),
  });
  vi.stubGlobal('fetch', fetchUsage);
  const { rerender } = render(Summary, { accountId: 'a', agentId: 'b', subscription });
  expect(await screen.findByText('40% used')).toBeVisible();
  for (let i = 0; i < 5; i++) {
    await rerender({ accountId: 'a', agentId: 'b', subscription: structuredClone(subscription) });
  }
  expect(fetchUsage).toHaveBeenCalledTimes(1);
  expect(screen.getByText('40% used')).toBeVisible();
});

test('refreshes once a minute without blanking bars or overlapping requests, and stops on unmount', async () => {
  vi.useFakeTimers();
  const snapshot = {
    status: 'available',
    windows: [{ label: 'Weekly', remaining_percent: 60, resets_at: new Date(Date.now() + 86400000).toISOString() }],
  };
  let finishRefresh;
  const fetchUsage = vi
    .fn()
    .mockResolvedValueOnce({ ok: true, json: async () => snapshot })
    .mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finishRefresh = resolve;
        })
    );
  vi.stubGlobal('fetch', fetchUsage);
  const { unmount } = render(Summary, { accountId: 'a', agentId: 'b', subscription });
  await vi.advanceTimersByTimeAsync(0);
  await tick();
  expect(screen.getByText('40% used')).toBeVisible();
  await vi.advanceTimersByTimeAsync(59_999);
  expect(fetchUsage).toHaveBeenCalledTimes(1);
  await vi.advanceTimersByTimeAsync(1);
  expect(fetchUsage).toHaveBeenCalledTimes(2);
  expect(screen.getByText('40% used')).toBeVisible();
  expect(screen.queryByText('Checking usage…')).not.toBeInTheDocument();
  await vi.advanceTimersByTimeAsync(60_000);
  expect(fetchUsage).toHaveBeenCalledTimes(2);
  finishRefresh({ ok: true, json: async () => snapshot });
  await vi.advanceTimersByTimeAsync(0);
  unmount();
  expect(fetchUsage.mock.calls[1][1].signal.aborted).toBe(true);
  await vi.advanceTimersByTimeAsync(120_000);
  expect(fetchUsage).toHaveBeenCalledTimes(2);
});

test('ignores an old request after switching residents and clears usage on disconnect', async () => {
  let finishOld;
  const fetchUsage = vi
    .fn()
    .mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finishOld = resolve;
        })
    )
    .mockResolvedValue({ ok: true, json: async () => ({ status: 'available', windows: [] }) });
  vi.stubGlobal('fetch', fetchUsage);
  const { rerender } = render(Summary, { accountId: 'a', agentId: 'b', subscription });
  await tick();
  await rerender({ accountId: 'a', agentId: 'c', subscription });
  expect(await screen.findByText('Usage unavailable')).toBeVisible();
  expect(fetchUsage).toHaveBeenCalledTimes(2);
  expect(fetchUsage.mock.calls[0][1].signal.aborted).toBe(true);
  finishOld({ ok: true, json: async () => ({ status: 'limited', windows: [] }) });
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(screen.queryByText('Subscription limit reached')).not.toBeInTheDocument();
  await rerender({ accountId: 'a', agentId: 'c', subscription: { ...subscription, connection: {} } });
  expect(await screen.findByText('Subscription not connected')).toBeVisible();
  expect(fetchUsage).toHaveBeenCalledTimes(2);
});

const lost = {
  id: 'lume',
  name: 'Lume',
  provider: 'anthropic',
  provider_name: 'Claude',
  available: true,
  auth_mode: 'oauth_account',
  connection: { status: 'expired' },
};

function providerFetch({ supported = true, poll = { status: 'pending' } } = {}) {
  return vi.fn((url, options = {}) => {
    const json = (body) => Promise.resolve({ ok: true, json: async () => body });
    if (url.includes('capabilities=1')) return json({ providers: { anthropic: { oauth_account: supported } } });
    if (options.method === 'POST')
      return json({ status: 'awaiting_code', verification_url: 'https://claude.example/sign-in' });
    if (url.includes('?provider=')) return json(poll);
    return json({});
  });
}

test('offers no reconnect button unless the viewer can manage the subscription', async () => {
  vi.stubGlobal('fetch', providerFetch());
  render(Summary, { accountId: 'a', agentId: 'lume', subscription: lost });
  expect(await screen.findByText('Subscription not connected')).toBeVisible();
  expect(screen.queryByRole('button', { name: 'Reconnect' })).not.toBeInTheDocument();
  expect(fetch).not.toHaveBeenCalled();
});

test('a lost subscription can be reconnected from the resident card', async () => {
  vi.stubGlobal('fetch', providerFetch());
  render(Summary, { accountId: 'a', agentId: 'lume', subscription: lost, canReconnect: true });
  const button = await screen.findByRole('button', { name: 'Reconnect' });
  await waitFor(() => expect(button).toBeEnabled());
  await fireEvent.click(button);
  expect(await screen.findByText('Open Claude sign-in')).toBeVisible();
  const start = fetch.mock.calls.find(([, options]) => options?.method === 'POST');
  expect(start[0]).toBe('/accounts/a/residents/lume/provider_subscription');
  expect(JSON.parse(start[1].body)).toEqual({ provider: 'anthropic' });
});

test('refreshes the resident cards once the sign-in completes', async () => {
  vi.stubGlobal('fetch', providerFetch({ poll: { status: 'connected', email: 'lume@example.com' } }));
  render(Summary, { accountId: 'a', agentId: 'lume', subscription: lost, canReconnect: true });
  const button = await screen.findByRole('button', { name: 'Reconnect' });
  await waitFor(() => expect(button).toBeEnabled());
  await fireEvent.click(button);
  await waitFor(() => expect(router.reload).toHaveBeenCalledWith({ only: ['agents'] }), { timeout: 4000 });
  expect(router.reload).toHaveBeenCalledTimes(1);
});

test('explains why reconnecting waits for an unhealthy runtime', async () => {
  vi.stubGlobal('fetch', providerFetch());
  render(Summary, {
    accountId: 'a',
    agentId: 'lume',
    subscription: { ...lost, available: false },
    canReconnect: true,
  });
  expect(await screen.findByRole('button', { name: 'Reconnect' })).toBeDisabled();
  expect(screen.getByText('The runtime needs to be healthy before it can be signed in again.')).toBeVisible();
});

test('hides the reconnect action when the runtime cannot sign in to a subscription', async () => {
  vi.stubGlobal('fetch', providerFetch({ supported: false }));
  render(Summary, { accountId: 'a', agentId: 'lume', subscription: lost, canReconnect: true });
  expect(await screen.findByText('This runtime does not support subscription sign-in.')).toBeVisible();
  expect(screen.getByRole('button', { name: 'Reconnect' })).toBeDisabled();
});
