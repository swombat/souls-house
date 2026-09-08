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
  expect(screen.getByLabelText('Mnemodyne nodes').parentElement).toHaveTextContent('1,234');
  expect(screen.getByLabelText('Journal entries').parentElement).toHaveTextContent('27');
  expect(screen.queryByText('Core:')).not.toBeInTheDocument();
  expect(screen.queryByText('Inactive:')).not.toBeInTheDocument();
});

test('keeps a failed measurement visibly stale', () => {
  render(AgentCard, {
    agent: { ...agent, journal_entry_stats: { count: 27, status: 'unavailable' } },
    accountId: 'test',
  });
  expect(screen.getByLabelText('Journal entries').parentElement).toHaveTextContent('27 (stale)');
});

test('distinguishes an unmeasured count from zero', () => {
  render(AgentCard, { agent: { ...agent, journal_entry_stats: {} }, accountId: 'test' });
  expect(screen.getByLabelText('Journal entries').parentElement).toHaveTextContent('—');
});

test('hides memory statistics for deprecated inline residents', () => {
  render(AgentCard, { agent: { ...agent, deprecated: true }, accountId: 'test' });
  expect(screen.queryByLabelText('Mnemodyne nodes')).not.toBeInTheDocument();
  expect(screen.queryByLabelText('Journal entries')).not.toBeInTheDocument();
});

test('shows the model subtitle, disk and integration permissions, never the prompt', () => {
  render(AgentCard, {
    agent: {
      ...agent,
      system_prompt: 'private prompt',
      journal_entry_stats: { storage_bytes: 1073741824 },
      integrations: [{ provider: 'github', label: 'owner/repo', enabled: false, status: 'disabled' }],
    },
    accountId: 'test',
  });
  expect(screen.getByText('test-model')).toHaveClass('font-light');
  expect(screen.queryByText('Model:')).not.toBeInTheDocument();
  expect(screen.queryByText('private prompt')).not.toBeInTheDocument();
  expect(screen.getByLabelText('Persistent disk used').parentElement).toHaveTextContent('1.0 GiB');
  expect(screen.getByTitle('owner/repo · disabled')).toHaveClass('text-muted-foreground/35');
});
