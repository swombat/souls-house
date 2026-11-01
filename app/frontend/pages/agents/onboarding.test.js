import { render, screen } from '@testing-library/svelte';
import Onboarding from './onboarding.svelte';
vi.mock('$lib/use-sync', () => ({ useSync: vi.fn() }));
const { reload } = vi.hoisted(() => ({ reload: vi.fn() }));
vi.mock('@inertiajs/svelte', async (importOriginal) => ({
  ...(await importOriginal()),
  router: { reload, post: vi.fn() },
}));

const agent = {
  id: 'resident',
  name: 'Resident',
  runtime: 'external',
  health_state: 'healthy',
  orientation_last_error: 'RAW PROVIDER ERROR: private diagnostic',
};

test('missing inference shows plain instructions and an edit link instead of raw errors or retry', () => {
  render(Onboarding, {
    account: { id: 'account' },
    agent: {
      ...agent,
      inference_setup_message: 'Edit the resident and set up credentials before asking them to respond.',
    },
  });
  expect(screen.getByRole('status')).toHaveTextContent('set up credentials');
  expect(screen.getByRole('link', { name: 'Edit Resident' })).toHaveAttribute(
    'href',
    '/accounts/account/residents/resident/edit'
  );
  expect(screen.queryByText(agent.orientation_last_error)).not.toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Try orientation again' })).not.toBeInTheDocument();
});

test('other orientation failures use a plain explanation without raw diagnostics', () => {
  render(Onboarding, { account: { id: 'account' }, agent });
  expect(screen.getByText('Their first wake did not complete')).toBeVisible();
  expect(screen.queryByText(agent.orientation_last_error)).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Try orientation again' })).toBeEnabled();
});

const ready = { ...agent, orientation_last_error: null, orientation_completed_at: '2026-10-26T15:00:00Z' };

test('the first conversation is linked as soon as it exists, before the resident has written', () => {
  render(Onboarding, {
    account: { id: 'account' },
    agent: ready,
    first_conversation: { id: 'chat1', has_reply: false },
  });
  expect(screen.getByRole('link', { name: /Open your first conversation/ })).toHaveAttribute(
    'href',
    '/accounts/account/chats/chat1'
  );
  expect(screen.queryByText(/Start your first conversation/)).not.toBeInTheDocument();
});

test('once the resident has written, the link says so', () => {
  render(Onboarding, {
    account: { id: 'account' },
    agent: ready,
    first_conversation: { id: 'chat1', has_reply: true },
  });
  expect(screen.getByRole('link', { name: /Read what Resident wrote/ })).toHaveAttribute(
    'href',
    '/accounts/account/chats/chat1'
  );
});

test('without a first conversation the page still offers to start one', () => {
  render(Onboarding, { account: { id: 'account' }, agent: ready });
  expect(screen.getByRole('link', { name: /Start your first conversation/ })).toBeVisible();
});

describe('watching for the first word', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    reload.mockClear();
  });
  afterEach(() => vi.useRealTimers());

  const firstWordReloads = () =>
    reload.mock.calls.filter(
      ([options]) => options.only.includes('first_conversation') && !options.only.includes('vm_steps')
    ).length;

  test('a slow setup does not use up the window: it starts when the first wake settles', async () => {
    const orienting = { ...ready, orientation_completed_at: null, orientation_requested_at: '2026-10-26T15:00:00Z' };
    const { rerender } = render(Onboarding, { account: { id: 'account' }, agent: orienting });
    await vi.advanceTimersByTimeAsync(15 * 60 * 1000);
    expect(firstWordReloads()).toBe(0);

    await rerender({ account: { id: 'account' }, agent: ready });
    await vi.advanceTimersByTimeAsync(9 * 60 * 1000);
    const during = firstWordReloads();
    expect(during).toBeGreaterThan(100);

    await vi.advanceTimersByTimeAsync(5 * 60 * 1000);
    expect(firstWordReloads()).toBeLessThanOrEqual(during + 21);
    const after = firstWordReloads();
    await vi.advanceTimersByTimeAsync(5 * 60 * 1000);
    expect(firstWordReloads()).toBe(after);
  });

  test('stops looking once the resident has written', async () => {
    render(Onboarding, {
      account: { id: 'account' },
      agent: ready,
      first_conversation: { id: 'chat1', has_reply: true },
    });
    await vi.advanceTimersByTimeAsync(60 * 1000);
    expect(firstWordReloads()).toBe(0);
  });
});
