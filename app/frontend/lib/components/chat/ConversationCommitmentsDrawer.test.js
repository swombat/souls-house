import { fireEvent, render, screen } from '@testing-library/svelte';
import { afterEach, expect, test, vi } from 'vitest';
import ConversationCommitmentsDrawer from './ConversationCommitmentsDrawer.svelte';

afterEach(() => vi.unstubAllGlobals());

function commitment(overrides = {}) {
  return {
    id: 'k1',
    status: 'scheduled',
    headline: 'Check the deploy receipt',
    text: 'Check the deploy receipt and tell Daniel.',
    resident_name: 'Lume',
    due_at: '2026-11-10T12:00:00Z',
    timezone: 'Europe/Madrid',
    destination: 'same_conversation',
    manage_url: '/accounts/a1/agents/r1/edit?tab=commitments',
    ...overrides,
  };
}

function stubFetch(body) {
  const fetch = vi.fn().mockResolvedValue({ ok: true, json: () => Promise.resolve(body) });
  vi.stubGlobal('fetch', fetch);
  return fetch;
}

test('fetches this conversation and lists waiting commitments with a manage link', async () => {
  const fetch = stubFetch({ waiting: [commitment()], earlier: [] });
  render(ConversationCommitmentsDrawer, { open: true, accountId: 'a1', chatId: 'c1' });

  expect(await screen.findByText('Check the deploy receipt')).toBeInTheDocument();
  expect(fetch).toHaveBeenCalledWith('/accounts/a1/chats/c1/commitments', expect.anything());
  expect(screen.getByText('Lume')).toBeInTheDocument();
  expect(screen.getByText(/10 Nov 2026/)).toBeInTheDocument();
  expect(screen.getByRole('link', { name: 'Reschedule or cancel' })).toHaveAttribute(
    'href',
    '/accounts/a1/agents/r1/edit?tab=commitments'
  );
});

test('says when nothing waits, and keeps finished ones behind a toggle', async () => {
  stubFetch({
    waiting: [],
    earlier: [
      commitment({ id: 'k2', status: 'cancelled', cancelled_at: '2026-11-09T10:00:00Z', headline: 'Old promise' }),
    ],
  });
  render(ConversationCommitmentsDrawer, { open: true, accountId: 'a1', chatId: 'c1' });

  expect(await screen.findByText('Nothing is waiting in this conversation.')).toBeInTheDocument();
  expect(screen.queryByText('Old promise')).toBeNull();
  await fireEvent.click(screen.getByRole('button', { name: /Show delivered and cancelled \(1\)/ }));
  expect(screen.getByText('Old promise')).toBeInTheDocument();
  expect(screen.queryByRole('link', { name: 'Reschedule or cancel' })).toBeNull();
});
