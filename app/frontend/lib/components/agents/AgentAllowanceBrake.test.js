import { render, screen, fireEvent } from '@testing-library/svelte';
import { writable, get } from 'svelte/store';
import AgentAllowanceBrake from './AgentAllowanceBrake.svelte';

function formWith(threshold = null) {
  return writable({
    agent: { allowance_brake_threshold_percent: threshold, scheduled_wakes_essential: false },
    errors: {},
  });
}

test('off by default and only an explicit enable chooses a threshold', async () => {
  const form = formWith();
  render(AgentAllowanceBrake, { form, canManage: true });
  expect(screen.queryByLabelText('Brake below remaining allowance (%)')).toBeNull();
  await fireEvent.click(screen.getByRole('switch', { name: 'Enable allowance brake' }));
  expect(get(form).agent.allowance_brake_threshold_percent).toBe(40);
  expect(screen.getByLabelText('Brake below remaining allowance (%)')).toHaveValue(40);
  await fireEvent.click(screen.getByRole('switch', { name: 'Enable allowance brake' }));
  expect(get(form).agent.allowance_brake_threshold_percent).toBeNull();
});

test('essential controls are hidden without management authority', () => {
  render(AgentAllowanceBrake, { form: formWith(40), canManage: false, status: { status: 'braked_stale' } });
  expect(screen.queryByRole('switch')).toBeNull();
  expect(screen.getByRole('status')).toHaveTextContent('Braked using an earlier low reading');
  expect(screen.getByText(/Only the owner or an account admin/)).toBeInTheDocument();
});

test('a zero threshold stays enabled and unavailable evidence is not called safe', () => {
  render(AgentAllowanceBrake, { form: formWith(0), canManage: true, status: { status: 'unavailable' } });
  expect(screen.getByLabelText('Brake below remaining allowance (%)')).toHaveValue(0);
  expect(screen.getByRole('status')).toHaveTextContent('Fresh allowance unavailable');
  expect(screen.getByText(/best-effort brake, not a spending cap/)).toBeInTheDocument();
});
