import { fireEvent, render, screen } from '@testing-library/svelte';
import { get, writable } from 'svelte/store';
import AgentSettingsPanel from './AgentSettingsPanel.svelte';

test('turn timeout binds minutes with a one-day upper bound', async () => {
  const form = writable({ agent: { turn_timeout_minutes: 30 }, errors: {} });
  render(AgentSettingsPanel, { form, runtimeManaged: true });
  const input = screen.getByLabelText('Turn timeout (minutes)');
  expect(input).toHaveValue(30);
  expect(input).toHaveAttribute('min', '1');
  expect(input).toHaveAttribute('max', '1440');
  await fireEvent.input(input, { target: { value: '1440' } });
  expect(get(form).agent.turn_timeout_minutes).toBe(1440);
  expect(screen.getByText(/Changes take effect on the next trigger/)).toBeInTheDocument();
});
