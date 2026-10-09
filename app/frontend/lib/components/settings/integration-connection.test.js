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

describe('sending as the owner (WhatsApp)', () => {
  const whatsapp = {
    provider: 'whatsapp',
    label: 'WhatsApp',
    management_scope: 'personal',
    can_manage: true,
    can_provision: true,
    residents: [
      {
        id: 'reader',
        name: 'Reader',
        enabled: true,
        can_send: false,
        access_update_url: '/a/r',
        send_grant_url: '/s/r',
      },
      {
        id: 'sender',
        name: 'Sender',
        enabled: true,
        can_send: true,
        access_update_url: '/a/s',
        send_grant_url: '/s/s',
      },
      { id: 'off', name: 'Off', enabled: false, can_send: false, access_update_url: '/a/o', send_grant_url: '/s/o' },
    ],
  };

  it('lets the owner grant and withdraw, and only for residents who can read', () => {
    mount({ ...whatsapp, can_grant_send: true });
    const boxes = screen.getAllByLabelText('Can send as you');
    expect(boxes).toHaveLength(2);
    for (const box of boxes) expect(box).toBeEnabled();
  });

  it('lets a manager who is not the owner withdraw but never grant', () => {
    mount({ ...whatsapp, can_grant_send: false });
    const [reader, sender] = screen.getAllByLabelText('Can send as you');
    expect(reader).not.toBeChecked();
    expect(reader).toBeDisabled();
    expect(sender).toBeChecked();
    expect(sender).toBeEnabled();
  });

  it('shows no send control on other services', () => {
    mount({ can_manage: true, can_provision: true });
    expect(screen.queryByLabelText('Can send as you')).not.toBeInTheDocument();
  });

  it('links the owner to the sends and grant history', () => {
    mount({ ...whatsapp, can_grant_send: true, comms_sends_url: '/accounts/a/service_connections/svc_1/comms_sends' });
    const link = screen.getByRole('link', { name: /What residents sent as you/ });
    expect(link).toHaveAttribute('href', '/accounts/a/service_connections/svc_1/comms_sends');
  });

  it('shows no sends link to anyone else', () => {
    mount({ ...whatsapp, can_grant_send: false, comms_sends_url: null });
    expect(screen.queryByRole('link', { name: /What residents sent as you/ })).not.toBeInTheDocument();
  });
});
