import { fireEvent, render, screen } from '@testing-library/svelte';
import { describe, expect, it, vi } from 'vitest';
import IntegrationConnection from './integration-connection.svelte';
import { submitNativePost } from '$lib/integration-forms';

vi.mock('$lib/integration-forms', () => ({ submitNativePost: vi.fn() }));

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
    open: true,
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
        {
          id: 'mira',
          name: 'Mira',
          enabled: true,
          access_update_url: '/access/mira',
          tailnet_url: '/t/mira',
          integrations_url: '/r/mira',
        },
        {
          id: 'lume',
          name: 'Lume',
          enabled: true,
          access_update_url: '/access/lume',
          tailnet_url: '/t/lume',
          integrations_url: '/r/lume',
        },
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

describe('a signed-in Telegram connection', () => {
  const telegram = {
    provider: 'telegram',
    label: 'Telegram',
    management_scope: 'personal',
    identity: 'Ada Example (@ada_example)',
    can_manage: true,
    can_provision: true,
    comms: {
      availability: { state: 'unavailable', reason: 'connector restarting' },
      search_all_dialogs: true,
      chats: 5,
      synced_chats: 3,
    },
  };

  it('shows who it is signed in as, the synced chats and the availability', () => {
    mount({ ...telegram, can_delegate: true });
    const status = screen.getByTestId('telegram-status');
    expect(status).toHaveTextContent('Ada Example (@ada_example)');
    expect(status).toHaveTextContent('3 of 5 chats synced');
    expect(status).toHaveTextContent('safely restart');
    expect(status).toHaveTextContent('Reason: connector restarting');
    expect(screen.getByLabelText(/Let residents search beyond the synced chats/)).toBeChecked();
  });

  it('keeps the search setting to the owner', () => {
    mount({ ...telegram, can_delegate: false, comms: { ...telegram.comms, availability: { state: 'ok' } } });
    expect(screen.queryByLabelText(/Let residents search beyond the synced chats/)).not.toBeInTheDocument();
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
  });
});

describe('a WhatsApp disconnect the connector has not confirmed', () => {
  const whatsapp = { provider: 'whatsapp', label: 'WhatsApp', management_scope: 'personal', can_manage: true };

  it('says the linked device may still be there, and how to remove it now', () => {
    mount({ ...whatsapp, status: 'revoked', comms: { chats: 3, unpair_pending: { attempts: 2 } } });
    expect(screen.getByTestId('unpair-pending')).toHaveTextContent(
      'the WhatsApp connector has not yet confirmed removing the linked device'
    );
    expect(screen.getByTestId('unpair-pending')).toHaveTextContent('Settings, Linked devices');
  });

  it('says nothing once the connector confirmed', () => {
    mount({ ...whatsapp, status: 'revoked', comms: { chats: 3 } });
    expect(screen.queryByTestId('unpair-pending')).not.toBeInTheDocument();
  });
});

describe('a WhatsApp connection waiting to be linked', () => {
  const whatsapp = { provider: 'whatsapp', label: 'WhatsApp', management_scope: 'personal', can_manage: true };

  it('offers the owner the pairing on its own page', () => {
    globalThis.fetch = vi.fn(() => new Promise(() => {}));
    mount({ ...whatsapp, status: 'pairing', can_delegate: true });
    expect(screen.getByTestId('whatsapp-link-page-link')).toHaveAttribute(
      'href',
      '/accounts/selected-house/service_connections/svc_test/pairing/link'
    );
  });

  it('offers nobody else the page', () => {
    globalThis.fetch = vi.fn(() => new Promise(() => {}));
    mount({ ...whatsapp, status: 'pairing', can_delegate: false });
    expect(screen.queryByTestId('whatsapp-link-page-link')).not.toBeInTheDocument();
  });
});

describe('the compact row', () => {
  it('keeps the controls closed until the row is opened', () => {
    render(IntegrationConnection, {
      account: { id: 'selected-house' },
      services: [],
      connection: { ...base, can_manage: true, can_provision: true },
    });
    expect(screen.getByRole('button', { name: 'Show details for Shared Dropbox' })).toHaveAttribute(
      'aria-expanded',
      'false'
    );
    expect(screen.queryByRole('button', { name: 'Disconnect' })).not.toBeInTheDocument();
  });
});

describe('sending as the owner (comms)', () => {
  const comms = {
    provider: 'whatsapp',
    label: 'WhatsApp',
    management_scope: 'personal',
    status: 'connected',
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
    mount({ ...comms, can_grant_send: true });
    const boxes = screen.getAllByLabelText('Can send as you');
    expect(boxes).toHaveLength(2);
    for (const box of boxes) expect(box).toBeEnabled();
  });

  it('lets a manager who is not the owner withdraw but never grant', () => {
    mount({ ...comms, can_grant_send: false });
    const [reader, sender] = screen.getAllByLabelText('Can send as you');
    expect(reader).not.toBeChecked();
    expect(reader).toBeDisabled();
    expect(sender).toBeChecked();
    expect(sender).toBeEnabled();
  });

  it('never offers a grant while the connection is not connected', () => {
    mount({ ...comms, can_grant_send: true, status: 'reauthorizing' });
    const [reader, sender] = screen.getAllByLabelText('Can send as you');
    expect(reader).toBeDisabled();
    expect(sender).toBeEnabled();
  });

  it('shows no send control where sending is not switched on (no send_grant_url)', () => {
    const residents = comms.residents.map(({ send_grant_url, can_send, ...resident }) => resident);
    mount({ ...comms, residents });
    expect(screen.queryByLabelText('Can send as you')).not.toBeInTheDocument();
  });

  it('links the owner to the sends and grant history, and no one else', () => {
    const { unmount } = mount({
      ...comms,
      can_grant_send: true,
      comms_sends_url: '/accounts/a/service_connections/svc_1/comms_sends',
    });
    const link = screen.getByRole('link', { name: /What residents sent as you/ });
    expect(link).toHaveAttribute('href', '/accounts/a/service_connections/svc_1/comms_sends');
    unmount();
    mount({ ...comms, can_grant_send: false });
    expect(screen.queryByRole('link', { name: /What residents sent as you/ })).not.toBeInTheDocument();
  });
});

describe('Disconnect warnings', () => {
  it('tells a Withings owner that issued tokens outlive the disconnect and how to revoke them', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false);
    mount({ provider: 'withings', label: 'Withings', management_scope: 'personal', can_manage: true });
    await fireEvent.click(screen.getByRole('button', { name: 'Disconnect' }));
    expect(confirm).toHaveBeenCalledTimes(1);
    const warning = confirm.mock.calls[0][0];
    expect(warning).toContain('until it expires (up to three hours)');
    expect(warning).toContain('remove the app from your Withings account');
    confirm.mockRestore();
  });
});

describe('LinkedIn sign-in that ends', () => {
  const linkedin = {
    provider: 'linkedin',
    provider_name: 'LinkedIn',
    label: 'Daniel Tenner',
    management_scope: 'personal',
    can_manage: true,
  };

  it('offers Reconnect in the last week, posting an ordinary Connect for the same service', async () => {
    const soon = new Date(Date.now() + 3 * 86_400_000 + 3_600_000).toISOString();
    mount({ ...linkedin, grant_expires_at: soon });
    expect(screen.getByTestId('grant-ending')).toHaveTextContent('ends in 3 days');
    await fireEvent.click(screen.getByTestId('connection-reconnect'));
    expect(submitNativePost).toHaveBeenCalledWith('/accounts/selected-house/service_authorizations', {
      provider: 'linkedin',
      management_scope: 'personal',
    });
  });

  it('says the sign-in has ended once it has, and still offers Reconnect', () => {
    mount({ ...linkedin, status: 'reauthorizing', grant_expires_at: '2026-01-01T00:00:00Z' });
    expect(screen.getByTestId('grant-ended')).toBeInTheDocument();
    expect(screen.getByTestId('connection-reconnect')).toBeInTheDocument();
  });

  it('shows nothing extra while the end is far off', () => {
    mount({ ...linkedin, grant_expires_at: new Date(Date.now() + 40 * 86_400_000).toISOString() });
    expect(screen.queryByTestId('connection-reconnect')).not.toBeInTheDocument();
  });
});
