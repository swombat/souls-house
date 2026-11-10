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
    cancellable: true,
    ...overrides,
  };
}

function lists({ outstanding = [], blocked = [], finished = [] } = {}, totals = {}) {
  const list = (items, name) => ({ items, total: totals[name] ?? items.length });
  return {
    outstanding: list(outstanding, 'outstanding'),
    blocked: list(blocked, 'blocked'),
    finished: list(finished, 'finished'),
  };
}

function stubFetch(body) {
  const fetch = vi.fn().mockResolvedValue({ ok: true, json: () => Promise.resolve(body) });
  vi.stubGlobal('fetch', fetch);
  return fetch;
}

test('fetches this conversation and lists waiting commitments with a manage link', async () => {
  const fetch = stubFetch(lists({ outstanding: [commitment()] }));
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
  stubFetch(
    lists({
      finished: [
        commitment({
          id: 'k2',
          status: 'cancelled',
          cancellable: false,
          cancelled_at: '2026-11-09T10:00:00Z',
          headline: 'Old promise',
        }),
      ],
    })
  );
  render(ConversationCommitmentsDrawer, { open: true, accountId: 'a1', chatId: 'c1' });

  expect(await screen.findByText('Nothing is waiting in this conversation.')).toBeInTheDocument();
  expect(screen.queryByText('Old promise')).toBeNull();
  await fireEvent.click(screen.getByRole('button', { name: /Show delivered and cancelled \(1\)/ }));
  expect(screen.getByText('Old promise')).toBeInTheDocument();
  expect(screen.queryByRole('link', { name: /Reschedule or cancel|Stop waking/ })).toBeNull();
  expect(screen.queryByRole('link', { name: 'Reschedule or cancel' })).toBeNull();
});

test('a posted commitment with a held wake is outstanding, not hidden as finished', async () => {
  stubFetch(
    lists({
      outstanding: [
        commitment({
          status: 'activated',
          wake_state: 'held',
          activated_at: '2026-11-10T12:00:00Z',
          headline: 'Held one',
        }),
      ],
    })
  );
  render(ConversationCommitmentsDrawer, { open: true, accountId: 'a1', chatId: 'c1' });

  expect(await screen.findByText('Held one')).toBeInTheDocument();
  expect(screen.queryByText('Nothing is waiting in this conversation.')).toBeNull();
  expect(screen.getByText(/was busy there, so the wake waits/)).toBeInTheDocument();
  expect(screen.getByRole('link', { name: 'Stop waking' })).toBeInTheDocument();
});

test('blocked wakes get their own section, and a capped list says so', async () => {
  stubFetch(
    lists(
      {
        outstanding: [commitment()],
        blocked: [
          commitment({
            id: 'k3',
            status: 'activated',
            wake_state: 'blocked',
            wake_reason: 'run_failed',
            cancellable: false,
            headline: 'Gave up',
          }),
        ],
      },
      { outstanding: 140 }
    )
  );
  render(ConversationCommitmentsDrawer, { open: true, accountId: 'a1', chatId: 'c1' });

  expect(await screen.findByText('The house stopped trying to wake the resident')).toBeInTheDocument();
  expect(screen.getByText('Gave up')).toBeInTheDocument();
  expect(screen.getByText(/stopped trying to wake Lume for it: run_failed/)).toBeInTheDocument();
  expect(screen.getByTestId('commitments-cap')).toHaveTextContent('Showing 1 of 140');
});
