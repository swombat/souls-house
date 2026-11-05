import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';
import { vi } from 'vitest';
import { router } from '@inertiajs/svelte';
import AgentCommitmentsPanel from './AgentCommitmentsPanel.svelte';

vi.mock('@inertiajs/svelte', () => ({ router: { delete: vi.fn(), patch: vi.fn() } }));

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

const commitments = {
  items: [
    {
      id: 'a',
      text: 'Check the rebuild receipt and tell Daniel',
      summary: 'Rebuild receipt',
      status: 'scheduled',
      due_at: '2026-11-03T02:00:00Z',
      timezone: 'Europe/Madrid',
      destination: 'same_conversation',
      waiting_reason: null,
      source_conversation_id: 'c1',
      source_conversation_title: 'Deploy thread',
      source_url: '/accounts/x/chats/c1',
      reschedule_count: 0,
      manage_url: '/accounts/x/residents/r/commitments/a',
    },
    {
      id: 'b',
      text: 'When you are back',
      status: 'scheduled',
      due_at: '2026-11-02T08:00:00Z',
      timezone: 'UTC',
      destination: 'new_conversation',
      room_name: 'Ops',
      waiting_reason: 'resident_paused',
      last_attempted_at: '2026-11-02T08:05:00Z',
      source_conversation_id: 'c1',
      source_conversation_title: 'Deploy thread',
      source_url: '/accounts/x/chats/c1',
      reschedule_count: 1,
      manage_url: null,
    },
    {
      id: 'c',
      text: 'Earlier promise',
      status: 'activated',
      due_at: '2026-11-01T08:00:00Z',
      activated_at: '2026-11-01T08:41:00Z',
      timezone: 'UTC',
      destination: 'same_conversation',
      wake_state: 'delivered',
      delivered_at: '2026-11-01T08:44:00Z',
      source_conversation_id: 'c1',
      source_conversation_title: 'Deploy thread',
      source_url: '/accounts/x/chats/c1',
      reschedule_count: 0,
      manage_url: null,
    },
  ],
};

test('shows scheduled, waiting and delivered commitments with their state', () => {
  render(AgentCommitmentsPanel, { commitments, agentName: 'Lume' });
  expect(screen.getByText('Check the rebuild receipt and tell Daniel')).toBeInTheDocument();
  expect(screen.getAllByTestId('commitment-summary').map((node) => node.textContent)).toEqual(['Rebuild receipt']);
  expect(screen.getByText(/Due 3 Nov 2026, 03:00/)).toBeInTheDocument();
  expect(screen.getByText(/Due and waiting: the resident is paused/)).toBeInTheDocument();
  expect(screen.getByText('New conversation in Ops')).toBeInTheDocument();
  expect(
    screen.getByText(/Posted 1 Nov 2026, 08:41\. Lume has it: the run that carried it finished 1 Nov 2026, 08:44/)
  ).toBeInTheDocument();
  expect(screen.getByText('Delivered and cancelled')).toBeInTheDocument();
  expect(screen.getAllByText('Deploy thread')[0]).toHaveAttribute('href', '/accounts/x/chats/c1');
  // Only the one the viewer may manage carries controls; there is no create.
  expect(screen.getAllByRole('button', { name: 'Cancel' })).toHaveLength(1);
  expect(screen.queryByRole('button', { name: /new|add|create/i })).toBeNull();
});

test('cancel and reschedule go to the manage url', async () => {
  vi.spyOn(window, 'confirm').mockReturnValue(true);
  render(AgentCommitmentsPanel, { commitments, agentName: 'Lume' });
  await fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
  expect(router.delete).toHaveBeenCalledWith('/accounts/x/residents/r/commitments/a', { preserveScroll: true });

  await fireEvent.click(screen.getByRole('button', { name: 'Reschedule' }));
  await fireEvent.input(screen.getByLabelText('New time'), { target: { value: '2026-11-04T09:30' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Save' }));
  expect(router.patch).toHaveBeenCalledWith(
    '/accounts/x/residents/r/commitments/a',
    { due_at: new Date('2026-11-04T09:30').toISOString() },
    expect.objectContaining({ preserveScroll: true })
  );
});

test('a posted commitment still being woken offers Stop, not Reschedule', async () => {
  vi.spyOn(window, 'confirm').mockReturnValue(true);
  const items = [
    {
      ...commitments.items[2],
      id: 'd',
      wake_state: 'retrying',
      wake_reason: 'resident_paused',
      manage_url: '/accounts/x/residents/r/commitments/d',
    },
  ];
  render(AgentCommitmentsPanel, { commitments: { items }, agentName: 'Lume' });
  expect(screen.queryByRole('button', { name: 'Reschedule' })).toBeNull();
  expect(screen.getByText(/can't be called back/)).toBeInTheDocument();
  await fireEvent.click(screen.getByRole('button', { name: 'Stop waking' }));
  expect(router.delete).toHaveBeenCalledWith('/accounts/x/residents/r/commitments/d', { preserveScroll: true });
});

test('says so when nothing is scheduled', () => {
  render(AgentCommitmentsPanel, { commitments: { items: [] }, agentName: 'Lume' });
  expect(screen.getByText('Lume has nothing scheduled.')).toBeInTheDocument();
});
