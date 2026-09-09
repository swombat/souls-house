import { render, screen } from '@testing-library/svelte';
import { afterEach, expect, test, vi } from 'vitest';
import Summary from './AgentSubscriptionUsageSummary.svelte';

const subscription = {
  available: true,
  provider: 'anthropic',
  auth_mode: 'oauth_account',
  connection: { status: 'connected' },
};
afterEach(() => vi.unstubAllGlobals());

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
