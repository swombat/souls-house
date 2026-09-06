import { fireEvent, render, screen } from '@testing-library/svelte';
import AgentRuntimeActivityCard from './AgentRuntimeActivityCard.svelte';

const base = {
  id: 'a',
  run_id: 'run',
  agent_name: 'Resident',
  active: true,
  status: 'running',
  status_label: 'is working',
  created_at: '2026-09-06T10:00:00Z',
  events: [],
};

test('minimises on completion, remains present and can be expanded again', async () => {
  const { container, rerender } = render(AgentRuntimeActivityCard, { interaction: base });
  const details = container.querySelector('details');
  expect(details.open).toBe(true);
  await rerender({
    interaction: {
      ...base,
      active: false,
      status: 'completed',
      status_label: 'finished',
      reply_label: '2 replies posted',
    },
  });
  expect(details.open).toBe(false);
  expect(screen.getByTestId('runtime-activity-card')).toBeInTheDocument();
  expect(screen.getByText(/2 replies posted/)).toBeInTheDocument();
  // jsdom does not implement the browser's native summary toggle default.
  details.open = true;
  await fireEvent(details, new Event('toggle'));
  expect(details.open).toBe(true);
});

test('completed cards start minimised and never expose diagnostic fields', () => {
  const { container } = render(AgentRuntimeActivityCard, {
    interaction: {
      ...base,
      active: false,
      status: 'completed',
      stdout: 'SECRET',
      stderr: 'SECRET',
      error_message: 'SECRET',
    },
  });
  expect(container.querySelector('details').open).toBe(false);
  expect(container.textContent).not.toContain('SECRET');
});

test('shows provider absence and lost reporting separately from execution failure', () => {
  render(AgentRuntimeActivityCard, {
    interaction: { ...base, reporter_health: 'stale', snapshot: { narration_capability: 'unsupported' } },
  });
  expect(screen.getByText(/Live updates interrupted/)).toBeInTheDocument();
  expect(screen.getByText(/Narration isn't available/)).toBeInTheDocument();
  expect(screen.getByText('is working')).toBeInTheDocument();
});
