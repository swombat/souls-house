import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';
import TailnetAccess from './tailnet-access.svelte';

const url = '/accounts/a/residents/lume/tailnet';

function respond(...bodies) {
  const fetchMock = vi.fn();
  for (const body of bodies) {
    fetchMock.mockResolvedValueOnce({ ok: true, status: 200, json: () => Promise.resolve(body) });
  }
  globalThis.fetch = fetchMock;
  return fetchMock;
}

const base = {
  available: true,
  provisioning_status: 'active',
  admin_url: 'https://login.tailscale.com/admin/machines',
};

describe('a resident’s Tailscale node', () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.useRealTimers();
  });

  it('starts a sign-in on request and shows the login link', async () => {
    const fetchMock = respond(
      { ...base, daemon: true, backend_state: 'NoState', hosts: [], pubkey: null },
      {
        ...base,
        daemon: true,
        backend_state: 'NeedsLogin',
        auth_url: 'https://login.tailscale.com/a/abc',
        hosts: [],
        pubkey: 'ssh-ed25519 AAAA soulshouse-lume',
      }
    );
    render(TailnetAccess, { url, agentName: 'Lume' });

    await fireEvent.click(await screen.findByRole('button', { name: 'Connect to Tailscale' }));
    const link = await screen.findByRole('link', { name: 'Sign in to Tailscale' });
    expect(link).toHaveAttribute('href', 'https://login.tailscale.com/a/abc');
    expect(fetchMock).toHaveBeenLastCalledWith(url, expect.objectContaining({ method: 'POST' }));
    expect(screen.getByText('ssh-ed25519 AAAA soulshouse-lume')).toBeInTheDocument();
  });

  it('once joined, lists the machines and how to switch key expiry off', async () => {
    respond({
      ...base,
      daemon: true,
      backend_state: 'Running',
      node: 'soulshouse-lume.tail1234.ts.net',
      hosts: [
        { alias: 'danbook', target: '100.64.0.3', online: false, os: 'macOS' },
        { alias: 'dell', target: '100.64.0.2', online: true, os: 'linux' },
      ],
      pubkey: 'ssh-ed25519 AAAA soulshouse-lume',
    });
    render(TailnetAccess, { url, agentName: 'Lume' });

    expect(await screen.findByText('ssh dell')).toBeInTheDocument();
    expect(screen.getByText('ssh danbook')).toBeInTheDocument();
    expect(screen.getByText('Disable Key Expiry')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Tailscale Machines page' })).toHaveAttribute(
      'href',
      'https://login.tailscale.com/admin/machines'
    );
  });

  it('explains a grant the container has not picked up yet', async () => {
    respond({
      available: false,
      provisioning_status: 'pending',
      error: 'no Tailscale integration is granted to this resident',
    });
    render(TailnetAccess, { url, agentName: 'Lume' });

    await waitFor(() =>
      expect(screen.getByText(/picks up Tailscale access when its container next restarts/)).toBeInTheDocument()
    );
  });
});
