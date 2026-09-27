import { render, screen } from '@testing-library/svelte';
import { expect, test } from 'vitest';
import Panel from './AgentCostsPanel.svelte';

const unestimated = [
  { agent_name: 'Wing', model: 'future-model', interaction_count: 2, reason: 'no price is configured for this model' },
];

test('shows unpriced usage even when there are no estimates', () => {
  render(Panel, { report: { unestimated } });
  expect(screen.getByRole('region', { name: 'Unestimated usage' })).toBeVisible();
  expect(screen.getByText(/unavailable does not mean free/)).toBeVisible();
  expect(screen.getByText(/future-model/)).toHaveTextContent('2 interactions');
  expect(screen.getByText(/No estimated interaction costs/)).toBeVisible();
  expect(screen.queryByText('≈$0.0000')).not.toBeInTheDocument();
});

test('shows partial totals alongside excluded usage', () => {
  render(Panel, { report: { unestimated, total_amount_usd: '1.25', interaction_count: 1, days: [] } });
  expect(screen.getByText('≈$1.25')).toBeVisible();
  expect(screen.getByRole('region', { name: 'Unestimated usage' })).toBeVisible();
});

test('does not warn when all recorded usage is priced', () => {
  render(Panel, { report: { unestimated: [], total_amount_usd: '1.25', interaction_count: 1, days: [] } });
  expect(screen.queryByRole('region', { name: 'Unestimated usage' })).not.toBeInTheDocument();
});
