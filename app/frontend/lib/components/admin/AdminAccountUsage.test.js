import { render, screen, fireEvent } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import AdminAccountUsage from './AdminAccountUsage.svelte';

function accountFixture() {
  return {
    id: 'account-one',
    use_system_ai_credentials: false,
    usage: {
      generated_at: '2026-09-05T12:00:00Z',
      summary: { agents: 0, active_agents: 0, conversations: 0, sessions: 0, runs: 0 },
      agents: [],
      activity: [
        { date: '2026-09-04', sessions: 0, runs: 0, conversations: 0 },
        { date: '2026-09-05', sessions: 0, runs: 0, conversations: 0 },
      ],
      integrations: [],
      ai_providers: [],
      recent_sessions: [],
      recent_conversations: [],
    },
  };
}

test('shows useful empty states and can refresh selected account data', async () => {
  render(AdminAccountUsage, { account: accountFixture() });
  expect(screen.getByText('No activity in this period.')).toBeInTheDocument();
  expect(screen.getByText('No residents have been created in this account.')).toBeInTheDocument();
  expect(screen.getByRole('heading', { name: 'Residents (0)' })).toBeInTheDocument();
  expect(document.body.textContent).not.toMatch(/\bagents?\b/i);
  expect(screen.getByRole('button', { name: 'Measure storage' })).toBeDisabled();
  await fireEvent.click(screen.getByRole('button', { name: 'Refresh overview' }));
  expect(router.reload).toHaveBeenCalledWith({ only: ['selected_account'] });
});

test('shows resident settings, failed storage freshness, integration status and scoped measurement action', async () => {
  const account = accountFixture();
  account.usage.agents = [
    {
      id: 'agent-one',
      name: 'Example resident',
      runtime: 'offline',
      active: true,
      paused: true,
      health_state: 'unhealthy',
      model: 'Example model',
      model_id: 'anthropic/claude-opus-4',
      model_access: { provider: 'anthropic', mode: 'oauth_account', connection_status: 'connected' },
      colour: 'violet',
      icon: 'Moon',
      reasoning_effort: 'high',
      scheduled_wakes_enabled: true,
      heartbeat_wakes_per_day: 4,
      conversations: 3,
      sessions: 5,
      runs: 12,
      enabled_tools: [],
      provider_auth: [],
      telegram: { configured: false },
      services: [],
      storage: {
        bytes: 1048576,
        status: 'unavailable',
        measured_at: '2026-09-04T12:00:00Z',
        volumes: { identity: 1048576 },
      },
    },
  ];
  account.usage.integrations = [
    {
      label: 'Work GitHub',
      provider: 'github',
      status: 'suspended',
      scope: 'account_managed',
      agents: ['Example resident'],
    },
  ];
  render(AdminAccountUsage, { account });
  expect(screen.getByRole('heading', { name: 'Example resident' })).toBeInTheDocument();
  expect(screen.getByText('Example model')).toBeInTheDocument();
  expect(screen.getByAltText('Anthropic logo')).toHaveAttribute('src', '/model-providers/anthropic.svg');
  expect(screen.getByLabelText('Example resident icon')).toHaveClass('bg-violet-100');
  expect(screen.getByText('OAuth · Anthropic')).toBeInTheDocument();
  expect(screen.getByText('4 wakes/day')).toBeInTheDocument();
  expect(screen.getByText('unavailable · stale')).toBeInTheDocument();
  expect(screen.getByText('Latest check failed; any size shown is an older reading.')).toBeInTheDocument();
  expect(screen.getByText('Work GitHub')).toBeInTheDocument();
  expect(screen.getByText('suspended')).toBeInTheDocument();
  expect(document.body.textContent).not.toMatch(/\bagents?\b/i);
  await fireEvent.click(screen.getByRole('button', { name: 'Measure storage' }));
  expect(router.post).toHaveBeenCalledWith('/admin/accounts/account-one/refresh_storage', {}, expect.any(Object));
});

test('greys out deprecated inline residents and omits external labels on hosted residents', () => {
  const account = accountFixture();
  const resident = {
    id: 'hosted',
    name: 'Hosted resident',
    runtime: 'external',
    active: true,
    model: 'Example',
    model_id: 'openai/gpt-5.5',
    model_access: { provider: 'openrouter', mode: 'api_key' },
    storage: {},
    enabled_tools: [],
    provider_auth: [],
    services: [],
    telegram: {},
  };
  account.usage.agents = [resident, { ...resident, id: 'old', name: 'Old resident', runtime: 'inline' }];
  render(AdminAccountUsage, { account });
  const deprecated = screen.getByRole('heading', { name: 'Old resident' }).closest('article');
  expect(deprecated).toHaveClass('grayscale', 'opacity-60');
  expect(screen.getByText('Deprecated · inline')).toBeInTheDocument();
  expect(screen.queryByText('external', { exact: true })).not.toBeInTheDocument();
  expect(screen.getAllByText('API · OpenRouter')).toHaveLength(2);
  expect(screen.getAllByRole('link', { name: 'Inspect runtime →' })).toHaveLength(1);
});

test('switches chart metrics without navigation and links sessions to admin runtime details', async () => {
  const account = accountFixture();
  account.usage.activity[1] = { date: '2026-09-05', sessions: 2, runs: 5, conversations: 1 };
  account.usage.recent_sessions = [
    {
      agent_id: 'agent-one',
      agent_name: 'Example resident',
      session_id: 'session/one',
      first_at: '2026-09-05T09:00:00Z',
      last_at: '2026-09-05T11:00:00Z',
      runs: 4,
    },
  ];
  render(AdminAccountUsage, { account });
  expect(screen.getByRole('img')).toHaveAttribute('aria-label', expect.stringContaining('daily peak 2'));
  await fireEvent.change(screen.getByLabelText('Activity metric'), { target: { value: 'runs' } });
  expect(screen.getByRole('img')).toHaveAttribute('aria-label', expect.stringContaining('daily peak 5'));
  const link = screen.getByRole('link', { name: 'Example resident' });
  expect(link.getAttribute('href')).toContain('/admin/agents/agent-one/runtime?');
  expect(link.getAttribute('href')).toContain('session_id=session%2Fone');
});
