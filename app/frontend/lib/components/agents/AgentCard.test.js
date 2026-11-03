import { render, screen } from '@testing-library/svelte';
import AgentCard from './AgentCard.svelte';

const agent = {
  id: 'test',
  name: 'Test resident',
  active: true,
  model_id: 'test-model',
  mnemodyne_node_count: 1234,
  mnemodyne_edge_count: 2345,
  journal_entry_stats: { count: 27, status: 'measured', measured_at: '2026-09-06T09:00:00Z' },
  memory_token_summary: { core: 100, active_journal: 200, inactive_journal: 300 },
};

test('shows node and entry counts, not retired token totals', () => {
  render(AgentCard, { agent, accountId: 'test' });
  expect(screen.getByLabelText('Mnemodyne nodes / connections').parentElement).toHaveTextContent('1,234 / 2,345');
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
  expect(screen.queryByLabelText('Mnemodyne nodes / connections')).not.toBeInTheDocument();
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

test('shows an empty graph as zero nodes and connections', () => {
  render(AgentCard, { agent: { ...agent, mnemodyne_node_count: 0, mnemodyne_edge_count: 0 }, accountId: 'test' });
  expect(screen.getByLabelText('Mnemodyne nodes / connections').parentElement).toHaveTextContent('0 / 0');
});

test('says nothing about failures when the last runs did not fail', () => {
  render(AgentCard, { agent, accountId: 'test' });
  expect(screen.queryByTestId('failed-runs')).not.toBeInTheDocument();
});

test('shows a failure streak, and calls the runtime not starting only when the streak says so', () => {
  const since = new Date();
  since.setHours(6, 20, 0, 0);
  const { unmount } = render(AgentCard, {
    agent: { ...agent, failed_runs: { count: 3, since: since.toISOString(), runtime_unavailable: false } },
    accountId: 'test',
  });
  const box = screen.getByTestId('failed-runs');
  expect(box).toHaveTextContent(/Last 3 runs failed \(since 0?6:20/);
  expect(box).not.toHaveTextContent("runtime isn't starting");
  unmount();

  render(AgentCard, {
    agent: { ...agent, failed_runs: { count: 2, since: since.toISOString(), runtime_unavailable: true } },
    accountId: 'test',
  });
  expect(screen.getByTestId('failed-runs')).toHaveTextContent("Test resident's runtime isn't starting");
});

test('says the model is unavailable when every failure in the streak was a refused model', () => {
  render(AgentCard, {
    agent: {
      ...agent,
      failed_runs: { count: 4, since: new Date().toISOString(), runtime_unavailable: false, model_unavailable: true },
    },
    accountId: 'test',
  });
  const box = screen.getByTestId('failed-runs');
  expect(box).toHaveTextContent("Test resident's model isn't available on its subscription");
  expect(box).not.toHaveTextContent("runtime isn't starting");
});

test('says what setup is missing when every failure was refused before dispatch', () => {
  render(AgentCard, {
    agent: {
      ...agent,
      inference_setup_message: 'Edit the resident and set up credentials before asking them to respond.',
      failed_runs: { count: 8, since: new Date().toISOString(), runtime_unavailable: false, needs_setup: true },
    },
    accountId: 'test',
  });
  expect(screen.getByTestId('failed-runs-needs-setup')).toHaveTextContent('set up credentials');
  expect(screen.getByTestId('failed-runs')).not.toHaveTextContent("runtime isn't starting");
});

test('names the shared cause when the streak has one and no more specific line applies', () => {
  render(AgentCard, {
    agent: {
      ...agent,
      failed_runs: {
        count: 3,
        since: new Date().toISOString(),
        runtime_unavailable: false,
        cause: "the house's model provider refused a request it made",
      },
    },
    accountId: 'test',
  });
  expect(screen.getByTestId('failed-runs-cause')).toHaveTextContent(
    "Each one failed because the house's model provider refused a request it made.",
  );
});

test('a more specific line wins over the shared cause', () => {
  render(AgentCard, {
    agent: {
      ...agent,
      failed_runs: { count: 2, since: new Date().toISOString(), runtime_unavailable: true, cause: 'x' },
    },
    accountId: 'test',
  });
  expect(screen.queryByTestId('failed-runs-cause')).not.toBeInTheDocument();
});

test('an asleep resident says so, and why, without claiming it is paused', () => {
  render(AgentCard, { agent: { ...agent, unavailability_reason: 'billing_hold' }, accountId: 'test' });
  const badge = screen.getByText('Asleep');
  expect(badge).toHaveAttribute('title', expect.stringMatching(/payment .* has lapsed/));
  expect(screen.queryByText('Paused')).not.toBeInTheDocument();
});

test('the admin grid shows where a resident runs and its owner', () => {
  render(AgentCard, {
    agent: {
      ...agent,
      hosting: { kind: 'cloud', state: 'ready', location: 'fsn1' },
      owner_email: 'owner@example.com',
      account_name: 'Owner account',
    },
    accountId: 'test',
    admin: true,
    showActions: false,
  });
  expect(screen.getByTestId('resident-hosting')).toHaveAttribute('data-kind', 'cloud');
  expect(screen.getByLabelText('Own cloud VM (fsn1)')).toBeInTheDocument();
  expect(screen.getByTestId('resident-owner')).toHaveTextContent('owner@example.com');
});

test('an account card shows neither hosting nor owner', () => {
  render(AgentCard, { agent, accountId: 'test' });
  expect(screen.queryByTestId('resident-hosting')).not.toBeInTheDocument();
  expect(screen.queryByTestId('resident-owner')).not.toBeInTheDocument();
});
