import { render } from '@testing-library/svelte';
import { expect, test, vi } from 'vitest';
import Costs from './costs.svelte';

const { update } = vi.hoisted(() => ({ update: vi.fn() }));
vi.mock('$lib/use-sync', () => ({ createDynamicSync: () => update }));

test('costs use only account roster/cost lanes, even as the resident set changes', async () => {
  const { rerender } = render(Costs, { account: { id: 'home', name: 'Home' }, agents: [] });
  const expected = {
    'HomeResidentRoster:home': ['agents', 'cost_report'],
    'AccountCostActivity:home': ['cost_report'],
  };
  expect(update).toHaveBeenLastCalledWith(expected);
  await rerender({ account: { id: 'home', name: 'Renamed' }, agents: [{ id: 'new-home' }] });
  expect(update).toHaveBeenLastCalledWith(expected);
  for (const [mapping] of update.mock.calls) expect(Object.keys(mapping).some((key) => key.startsWith('Agent:'))).toBe(false);
  await rerender({ account: { id: 'other', name: 'Other' }, agents: [] });
  expect(update).toHaveBeenLastCalledWith({
    'HomeResidentRoster:other': ['agents', 'cost_report'],
    'AccountCostActivity:other': ['cost_report'],
  });
});
