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

  const joined = {
    ...base,
    daemon: true,
    backend_state: 'Running',
    node: 'soulshouse-lume.tail1234.ts.net',
    hosts: [
      { alias: 'danbook', target: '100.64.0.3', online: false, os: 'macOS' },
      { alias: 'dell', target: '100.64.0.2', online: true, os: 'linux' },
    ],
    pubkey: 'ssh-ed25519 AAAA soulshouse-lume',
  };

  it('once joined, lists the machines, the login account to name, and how to switch key expiry off', async () => {
    respond(joined, joined);
    render(TailnetAccess, { url, agentName: 'Lume' });

    expect(await screen.findByText('dell')).toBeInTheDocument();
    expect(screen.getByText('danbook')).toBeInTheDocument();
    expect(screen.getByText(/doesn't say which account to log in as/)).toBeInTheDocument();
    expect(screen.getByText('Disable Key Expiry')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Tailscale Machines page' })).toHaveAttribute(
      'href',
      'https://login.tailscale.com/admin/machines'
    );
  });

  it('opening the panel on a node that joined while it was closed writes the SSH aliases once', async () => {
    const fetchMock = respond(joined, joined);
    render(TailnetAccess, { url, agentName: 'Lume' });

    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
    expect(fetchMock.mock.calls.map(([, options]) => options.method)).toEqual(['GET', 'POST']);
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('closing the panel mid-request aborts it and schedules nothing more', async () => {
    vi.useFakeTimers();
    let resolveFirst;
    const fetchMock = vi.fn((_url, options) => {
      return new Promise((resolve, reject) => {
        resolveFirst = () =>
          resolve({
            ok: true,
            status: 200,
            json: () =>
              Promise.resolve({
                ...base,
                backend_state: 'NeedsLogin',
                auth_url: 'https://login.tailscale.com/a/x',
                hosts: [],
              }),
          });
        options.signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
      });
    });
    globalThis.fetch = fetchMock;

    const { unmount } = render(TailnetAccess, { url, agentName: 'Lume' });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const { signal } = fetchMock.mock.calls[0][1];
    unmount();
    expect(signal.aborted).toBe(true);
    resolveFirst();
    await vi.advanceTimersByTimeAsync(20000);
    expect(fetchMock).toHaveBeenCalledTimes(1);
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

  it('on the account screen, a joined node is one line with a link to its tab', async () => {
    respond(joined, joined);
    render(TailnetAccess, { url, agentName: 'Lume', compact: true, pageUrl: '/accounts/a/residents/lume/edit?tab=integrations' });
    const line = await screen.findByTestId('tailnet-joined');
    expect(line).toHaveTextContent('can reach 2 machines');
    expect(screen.getByRole('link', { name: 'SSH key and machines' })).toHaveAttribute(
      'href',
      '/accounts/a/residents/lume/edit?tab=integrations'
    );
    expect(screen.queryByText('ssh-ed25519 AAAA soulshouse-lume')).not.toBeInTheDocument();
  });
});
