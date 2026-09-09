import { render, screen, fireEvent } from '@testing-library/svelte';
import AgentGrid from './AgentGrid.svelte';

const active = { id: 'a', name: 'Active', active: true, model_id: 'example' };
test('hides the checkbox when every resident is active', () => {
  render(AgentGrid, { agents: [active], accountId: 'one' });
  expect(screen.queryByRole('checkbox')).not.toBeInTheDocument();
});
test('reveals disabled then deprecated residents below active cards, reversibly', async () => {
  render(AgentGrid, {
    agents: [
      { ...active, id: 'old', name: 'Deprecated', deprecated: true },
      { ...active, id: 'off', name: 'Disabled', active: false },
      active,
    ],
    accountId: 'one',
  });
  const checkbox = screen.getByRole('checkbox', { name: 'Show disabled' });
  expect(checkbox).not.toBeChecked();
  expect(screen.getAllByRole('heading').map((h) => h.textContent)).toEqual(['Active']);
  await fireEvent.click(checkbox);
  expect(screen.getAllByRole('heading').map((h) => h.textContent)).toEqual(['Active', 'Disabled', 'Deprecated']);
  expect(screen.getByRole('separator')).toBeVisible();
  await fireEvent.click(checkbox);
  expect(screen.queryByRole('heading', { name: 'Deprecated' })).not.toBeInTheDocument();
});
