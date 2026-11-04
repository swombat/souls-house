import { cleanup, render, screen } from '@testing-library/svelte';
import { afterEach, expect, test, vi } from 'vitest';
import EditResident from './edit.svelte';

vi.mock('$lib/cable', () => ({ subscribeToModel: vi.fn(() => vi.fn()) }));
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

const subscription = {
  id: 'resident',
  name: 'Resident',
  provider: 'anthropic',
  provider_name: 'Claude',
  available: false,
  connection: { status: 'expired' },
};

test('owners never see the Hosting tab; an old ?tab=hosting link lands on Settings with the subscription', () => {
  render(EditResident, {
    account: { id: 'first' },
    agent: { id: 'resident', name: 'Resident', runtime: 'external', health_state: 'healthy' },
    provider_subscription: subscription,
    active_tab: 'hosting',
  });
  expect(screen.queryByRole('button', { name: /Hosting/ })).toBeNull();
  expect(screen.getByText('Claude Code clamping')).toBeInTheDocument();
  expect(screen.queryByTestId('runtime-status')).toBeNull();
});

test('site admins still get the Hosting tab', () => {
  render(EditResident, {
    account: { id: 'first' },
    agent: { id: 'resident', name: 'Resident', runtime: 'external' },
    can_view_hosting: true,
    active_tab: 'settings',
  });
  expect(screen.getByRole('button', { name: /Hosting/ })).toBeInTheDocument();
});

test('an unhealthy resident shows a plain status line, and Restart only for the owner', async () => {
  const props = {
    account: { id: 'first' },
    agent: {
      id: 'resident',
      name: 'Resident',
      runtime: 'external',
      health_state: 'unhealthy',
      sandbox_last_error: 'container exited 137',
    },
    sandbox_recreation_url: '/accounts/first/agents/resident/sandbox_recreation',
    active_tab: 'settings',
  };
  const view = render(EditResident, props);
  expect(screen.getByText("Resident isn't responding right now.")).toBeInTheDocument();
  expect(screen.getByText('container exited 137')).toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Restart' })).toBeNull();
  await view.rerender({ ...props, can_restart_runtime: true });
  expect(screen.getByRole('button', { name: 'Restart' })).toBeInTheDocument();
});

test('a deprecated resident says so on Settings, with no Restart', () => {
  render(EditResident, {
    account: { id: 'first' },
    agent: { id: 'resident', name: 'Resident', runtime: 'deprecated', deprecated: true, health_state: 'unhealthy' },
    can_restart_runtime: true,
    sandbox_recreation_url: '/x',
    active_tab: 'settings',
  });
  expect(screen.getByText(/has no supported harness and cannot respond/)).toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Restart' })).toBeNull();
});
