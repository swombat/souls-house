import { render, screen } from '@testing-library/svelte';
import { describe, expect, it } from 'vitest';
import AgentIntegrationsPanel from './AgentIntegrationsPanel.svelte';

function shared(attributes) {
  return {
    id: 'svc_drive',
    provider: 'google_workspace',
    provider_name: 'Google Workspace',
    identity: 'anna@example.test',
    label: 'anna@example.test',
    shared_from: "Anna's house",
    shared_by: 'Anna',
    effective_authority: { drive: 'read' },
    enabled: true,
    effective: false,
    home_approval: 'pending',
    home_approval_generation: 3,
    decision_url: '/decide',
    history: [],
    ...attributes,
  };
}

function mount(sharedConnections, canDecideGuestAccess = true) {
  return render(AgentIntegrationsPanel, {
    account: { id: 'home' },
    agent: { name: 'Lume', telegram_configured: false },
    sharedConnections,
    canDecideGuestAccess,
  });
}

describe('connections shared from other houses', () => {
  it('is absent when nothing is shared', () => {
    mount([]);
    expect(screen.queryByTestId('shared-from-other-houses')).not.toBeInTheDocument();
    expect(screen.queryByTestId('shared-awaiting-approval')).not.toBeInTheDocument();
  });

  it('puts a request waiting for approval above the integrations, and a decided one back at the bottom', () => {
    const { container } = mount([
      shared({ id: 'svc_waiting' }),
      shared({ id: 'svc_done', label: 'done@example.test', home_approval: 'approved', effective: true }),
    ]);
    const waiting = screen.getByTestId('shared-awaiting-approval');
    const decided = screen.getByTestId('shared-from-other-houses');
    expect(waiting).toHaveTextContent('Access approval needed');
    expect(waiting).toHaveTextContent('anna@example.test');
    expect(waiting).not.toHaveTextContent('done@example.test');
    expect(decided).toHaveTextContent('done@example.test');

    const telegram = screen.getByText('Telegram');
    const order = [waiting, telegram, decided].map((node) => [...container.querySelectorAll('*')].indexOf(node));
    expect(order).toEqual([...order].sort((a, b) => a - b));
  });

  it('shows no waiting section once nothing is pending', () => {
    mount([shared({ home_approval: 'approved', effective: true })]);
    expect(screen.queryByTestId('shared-awaiting-approval')).not.toBeInTheDocument();
    expect(screen.getByTestId('shared-from-other-houses')).toBeInTheDocument();
  });

  it('shows the offer with its authority and lets an owner approve or decline', () => {
    mount([shared()]);
    expect(screen.getByTestId('shared-status')).toHaveTextContent("Anna's house wants to share this with Lume.");
    expect(screen.getByText(/Authority: Drive: read only/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Approve' })).toBeEnabled();
    expect(screen.getByRole('button', { name: 'Decline' })).toBeEnabled();
    expect(screen.queryByRole('button', { name: 'Revoke' })).not.toBeInTheDocument();
  });

  it('tells a member that only an owner decides', () => {
    mount([shared()], false);
    expect(screen.getByRole('button', { name: 'Approve' })).toBeDisabled();
    expect(screen.getByText('Only an owner of this account can decide.')).toBeInTheDocument();
  });

  it('offers revoke on an approval in use', () => {
    mount([
      shared({
        effective: true,
        home_approval: 'approved',
        home_approval_by_name: 'Daniel',
        home_approval_at: '2026-11-01T18:00:00Z',
      }),
    ]);
    expect(screen.getByText('In use')).toBeInTheDocument();
    expect(screen.getByTestId('shared-status')).toHaveTextContent(/^Approved by Daniel on /);
    expect(screen.getByRole('button', { name: 'Revoke' })).toBeEnabled();
  });
});
