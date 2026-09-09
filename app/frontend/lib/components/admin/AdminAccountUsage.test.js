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

test('uses shared resident cards without mutation buttons and can measure storage', async () => {
  const account = accountFixture();
  const resident = {
    id: 'one',
    name: 'Example resident',
    active: true,
    model_id: 'example',
    reasoning_effort: 'high',
    runtime: 'external',
    storage: {},
  };
  account.usage.agents = [resident];
  account.usage.resident_cards = [resident, { ...resident, id: 'old', name: 'Old resident', deprecated: true }];
  render(AdminAccountUsage, { account });
  expect(screen.getByRole('heading', { name: 'Example resident' })).toBeVisible();
  expect(screen.getByText('/ high')).toHaveClass('opacity-50');
  expect(screen.queryByRole('link', { name: 'Edit' })).not.toBeInTheDocument();
  expect(screen.queryByRole('button', { name: /Disable Example/ })).not.toBeInTheDocument();
  expect(screen.queryByRole('heading', { name: 'Old resident' })).not.toBeInTheDocument();
  await fireEvent.click(screen.getByRole('checkbox', { name: 'Show disabled' }));
  expect(screen.getByRole('heading', { name: 'Old resident' })).toBeVisible();
  expect(screen.getByText('Deprecated · Unavailable')).toBeVisible();
  await fireEvent.click(screen.getByRole('button', { name: 'Measure storage' }));
  expect(router.post).toHaveBeenCalledWith('/admin/accounts/account-one/refresh_storage', {}, expect.any(Object));
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

test('shows historical failures separately from the latest OAuth attempt and links its dated session', () => {
  const account = accountFixture();
  account.usage.recent_conversations = [
    {
      id: 'chat-one',
      title: 'Diagnostic conversation',
      agents: ['Janis'],
      messages: 4,
      resident_replies: 1,
      context_tokens: 120,
      message_tokens: { input: 120, output: 30 },
      runtime_tokens: { input: null, output: 0 },
      response_attempts: 2,
      failed_attempts: 1,
      latest_responses: [
        {
          agent_id: 'janis',
          agent_name: 'Janis',
          session_id: 'janis/session',
          status: 'completed',
          auth_mode: 'oauth_account',
          transport_status: 200,
          returncode: 0,
          started_at: '2026-09-01T12:00:00Z',
          finished_at: '2026-09-01T12:01:00Z',
        },
      ],
    },
  ];
  render(AdminAccountUsage, { account });
  expect(screen.getByText('4 messages · 1 resident replies')).toBeInTheDocument();
  expect(screen.getByText('1 failed (historical)')).toBeInTheDocument();
  expect(screen.getByText('completed')).toBeInTheDocument();
  expect(screen.getByText('Runtime tokens: — in / 0 out')).toBeInTheDocument();
  const url = new URL(screen.getByRole('link', { name: 'Janis' }).href);
  expect(url.searchParams.get('session_id')).toBe('janis/session');
  expect(url.searchParams.get('from')).toBe('2026-09-01T11:59:00.000Z');
  expect(url.searchParams.get('to')).toBe('2026-09-01T12:02:00.000Z');
});

test('does not call a conversation without recorded attempts successful', () => {
  const account = accountFixture();
  account.usage.recent_conversations = [
    {
      id: 'empty',
      title: 'Not attempted',
      agents: [],
      messages: 1,
      resident_replies: 0,
      response_attempts: 0,
      failed_attempts: 0,
      latest_responses: [],
    },
  ];
  render(AdminAccountUsage, { account });
  expect(screen.getByText('No recorded conversation attempts.')).toBeInTheDocument();
  expect(screen.queryByText('completed')).not.toBeInTheDocument();
});
