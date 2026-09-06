import { render, screen } from '@testing-library/svelte';
import AgentCard from './AgentCard.svelte';

const agent = {
  id: 'test',
  name: 'Test resident',
  active: true,
  model_id: 'test-model',
  mnemodyne_node_count: 1234,
  journal_entry_stats: { count: 27, status: 'measured', measured_at: '2026-09-06T09:00:00Z' },
  memory_token_summary: { core: 100, active_journal: 200, inactive_journal: 300 },
};

test('shows node and entry counts, not retired token totals', () => {
  render(AgentCard, { agent, accountId: 'test' });
  expect(screen.getByText('Mnemodyne nodes:').parentElement).toHaveTextContent('1,234');
  expect(screen.getByText('Journal entries:').parentElement).toHaveTextContent('27');
  expect(screen.queryByText('Core:')).not.toBeInTheDocument();
  expect(screen.queryByText('Inactive:')).not.toBeInTheDocument();
});

test('keeps a failed measurement visibly stale', () => {
  render(AgentCard, {
    agent: { ...agent, journal_entry_stats: { count: 27, status: 'unavailable' } },
    accountId: 'test',
  });
  expect(screen.getByText('Journal entries:').parentElement).toHaveTextContent('27 (stale)');
});

test('distinguishes an unmeasured count from zero', () => {
  render(AgentCard, { agent: { ...agent, journal_entry_stats: {} }, accountId: 'test' });
  expect(screen.getByText('Journal entries:').parentElement).toHaveTextContent('—');
});

test('hides memory statistics for deprecated inline residents', () => {
  render(AgentCard, { agent: { ...agent, deprecated: true }, accountId: 'test' });
  expect(screen.queryByText('Mnemodyne nodes:')).not.toBeInTheDocument();
  expect(screen.queryByText('Journal entries:')).not.toBeInTheDocument();
});
