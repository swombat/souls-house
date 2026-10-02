import { render, screen } from '@testing-library/svelte';
import { describe, expect, it } from 'vitest';
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
