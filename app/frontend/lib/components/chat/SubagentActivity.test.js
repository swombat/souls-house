import { render, screen } from '@testing-library/svelte';
import SubagentActivity from './SubagentActivity.svelte';

const helper = { ordinal: 1, nickname: 'Donny', model: 'gpt-6.1-sol', status: 'running' };

test('pulses while working, stops on completion and retains colour on reactivation', async () => {
  const { rerender } = render(SubagentActivity, { agents: [helper], active: true, compact: true });
  const dot = screen.getByRole('img', { name: 'Donny · Working' });
  const colour = dot.style.backgroundColor;
  expect(dot).toHaveClass('pulsing');
  await rerender({ agents: [{ ...helper, status: 'completed' }], active: true, compact: true });
  expect(screen.getByRole('img', { name: 'Donny · Completed' })).not.toHaveClass('pulsing');
  await rerender({ agents: [helper], active: true, compact: true });
  expect(dot).toHaveClass('pulsing');
  expect(dot.style.backgroundColor).toBe(colour);
});

test.each([{ active: false }, { active: true, stale: true }])(
  'does not claim continuing work or success when reports stop: %j',
  (state) => {
    render(SubagentActivity, { agents: [helper], compact: true, ...state });
    expect(screen.getByRole('img', { name: 'Donny · Status unconfirmed' })).not.toHaveClass('pulsing');
  }
);

test('details show only nickname, model and status, never roles or private fields', () => {
  const { container } = render(SubagentActivity, {
    agents: [
      { ...helper, prompt: 'SECRET', result: 'SECRET', error: 'SECRET' },
      { ordinal: 2, status: 'errored', agent_role: 'SECRET' },
    ],
    active: true,
  });
  expect(screen.getByText('Helpers started this turn')).toBeInTheDocument();
  expect(screen.getByText('Donny')).toBeInTheDocument();
  expect(screen.getByText('gpt-6.1-sol')).toBeInTheDocument();
  expect(screen.getByText('Helper 2')).toBeInTheDocument();
  expect(screen.getByText('Failed')).toBeInTheDocument();
  expect(container.textContent).not.toContain('SECRET');
  const dots = container.querySelectorAll('.helper-dot');
  expect(dots[0].style.backgroundColor).not.toBe(dots[1].style.backgroundColor);
});

test('ordinal, not position, determines colour', async () => {
  const second = { ...helper, ordinal: 2, nickname: 'Reviewer' };
  const { rerender } = render(SubagentActivity, { agents: [helper, second], active: true, compact: true });
  const colour = screen.getByRole('img', { name: 'Reviewer · Working' }).style.backgroundColor;
  await rerender({ agents: [second, helper], active: true, compact: true });
  expect(screen.getByRole('img', { name: 'Reviewer · Working' }).style.backgroundColor).toBe(colour);
});

test.each([false, true])('overflow is visible in compact=%s', (compact) => {
  render(SubagentActivity, { agents: [helper], overflow: 7, active: true, compact });
  expect(screen.getByText(/\+7 more/)).toBeInTheDocument();
});

test.each([false, true])('saturated counts stay visibly lower bounds in compact=%s', (compact) => {
  render(SubagentActivity, { agents: [helper], overflow: 992, overflowCapped: true, active: true, compact });
  expect(screen.getByText(/at least/i)).toBeInTheDocument();
});

test('old snapshots need no placeholder or invented helpers', () => {
  const { container } = render(SubagentActivity);
  expect(container.textContent).toBe('');
});
