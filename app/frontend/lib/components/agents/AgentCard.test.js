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

test('shows the daily heartbeat frequency only when enabled and unpaused', () => {
  render(AgentCard, {
    agent: { ...agent, scheduled_wakes_enabled: true, heartbeat_wakes_per_day: 8 },
    accountId: 'test',
  });
  expect(screen.getByLabelText('Daily heartbeats').parentElement).toHaveTextContent('8');
});

test.each([
  { scheduled_wakes_enabled: false },
  { scheduled_wakes_enabled: true, paused: true },
  { scheduled_wakes_enabled: true, active: false },
])('greys out an unavailable heartbeat: %o', (settings) => {
  render(AgentCard, { agent: { ...agent, heartbeat_wakes_per_day: 8, ...settings }, accountId: 'test' });
  expect(screen.getByLabelText('Heartbeats disabled').parentElement).toHaveClass('text-muted-foreground/40');
  expect(screen.queryByLabelText('Daily heartbeats')).not.toBeInTheDocument();
});

test('a disabled resident stays visible and editable with a disabled bin', () => {
  render(AgentCard, { agent: { ...agent, active: false }, accountId: 'test' });
  expect(screen.getByText('Disabled')).toBeVisible();
  expect(screen.getByRole('button', { name: 'Disable Test resident' })).toBeDisabled();
  expect(screen.getByRole('link', { name: 'Edit' })).toBeVisible();
  expect(screen.getByText('Test resident').closest('.grayscale')).not.toBeNull();
});

test('shows configured effort and labels an unspecified provider default honestly', () => {
  render(AgentCard, { agent: { ...agent, reasoning_effort: 'default' }, accountId: 'test', showActions: false });
  expect(screen.getByText('/ provider default')).toHaveClass('opacity-50');
  expect(screen.queryByRole('button')).not.toBeInTheDocument();
  expect(screen.queryByRole('link')).not.toBeInTheDocument();
});
