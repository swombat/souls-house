import { render, screen } from '@testing-library/svelte';
import { describe, expect, it, vi } from 'vitest';
import IntegrationConnection from './integration-connection.svelte';

const base = {
  id: 'svc_test',
  provider: 'dropbox',
  label: 'Shared Dropbox',
  management_scope: 'account_managed',
  connected_by_name: 'Account owner',
  status: 'connected',
  enabled_for_new_agents: false,
  freely_provisionable: false,
  can_delegate: false,
  residents: [
    { id: 'enabled', name: 'Enabled resident', enabled: true, access_update_url: '/access/enabled' },
    { id: 'disabled', name: 'Disabled resident', enabled: false, access_update_url: '/access/disabled' },
  ],
};

function mount(attributes) {
  return render(IntegrationConnection, {
    account: { id: 'selected-house' },
    services: [],
    connection: { ...base, ...attributes },
  });
}

describe('existing integration permission controls', () => {
  it('shows account integrations read-only to ordinary members', () => {
    mount({ can_manage: false, can_provision: false });
    expect(screen.queryByRole('button', { name: 'Disconnect' })).not.toBeInTheDocument();
    expect(screen.getByLabelText('Turn on for new residents automatically')).toBeDisabled();
    expect(screen.queryByLabelText('Let account admins switch this on for residents')).not.toBeInTheDocument();
    for (const control of screen.getAllByRole('switch')) expect(control).toBeDisabled();
  });

  it('distinguishes managing an existing grant from permission to provision', () => {
    mount({ management_scope: 'personal', can_manage: true, can_provision: false });
    expect(screen.getByRole('button', { name: 'Disconnect' })).toBeEnabled();
    expect(screen.getByRole('switch', { name: /Disable Shared Dropbox/ })).toBeEnabled();
    expect(screen.getByRole('switch', { name: /Enable Shared Dropbox/ })).toBeDisabled();
  });

  it('offers personal delegation only to the owner and prevents enabling disconnected credentials', () => {
    mount({
      management_scope: 'personal',
      can_manage: true,
      can_provision: true,
      can_delegate: true,
      status: 'reauthorizing',
    });
    expect(screen.getByLabelText('Let account admins switch this on for residents')).toBeEnabled();
    expect(screen.getByRole('switch', { name: /Disable Shared Dropbox/ })).toBeEnabled();
    expect(screen.getByRole('switch', { name: /Enable Shared Dropbox/ })).toBeDisabled();
  });
});

describe('Tailscale sign-in on the account screen', () => {
  it('shows a sign-in panel for each resident granted the tailnet, and none for the rest', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: () => Promise.resolve({ available: true, backend_state: 'NoState', hosts: [], pubkey: null }),
    });
    mount({
      provider: 'tailscale',
      label: 'Tailnet',
      can_manage: true,
      can_provision: true,
      residents: [
        { id: 'mira', name: 'Mira', enabled: true, access_update_url: '/access/mira', tailnet_url: '/t/mira', integrations_url: '/r/mira' },
        { id: 'lume', name: 'Lume', enabled: true, access_update_url: '/access/lume', tailnet_url: '/t/lume', integrations_url: '/r/lume' },
        { id: 'off', name: 'Off', enabled: false, access_update_url: '/access/off', tailnet_url: null },
      ],
    });
    const section = screen.getByTestId('tailnet-sign-ins');
    expect(section).toHaveTextContent('Mira');
    expect(section).toHaveTextContent('Lume');
    expect(section).not.toHaveTextContent('Off');
    expect(await screen.findAllByRole('button', { name: 'Connect to Tailscale' })).toHaveLength(2);
    expect(globalThis.fetch.mock.calls.map(([url]) => url).sort()).toEqual(['/t/lume', '/t/mira']);
  });

  it('adds nothing to other providers', () => {
    mount({ can_manage: true, can_provision: true });
    expect(screen.queryByTestId('tailnet-sign-ins')).not.toBeInTheDocument();
  });
});
