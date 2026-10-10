import { render, screen, fireEvent, within } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';
import ConnectionRepositories from './connection-repositories.svelte';
import IntegrationConnection from './integration-connection.svelte';

vi.mock('@inertiajs/svelte', async (importOriginal) => {
  const original = await importOriginal();
  return { ...original, router: { post: vi.fn(), delete: vi.fn(), patch: vi.fn() } };
});

afterEach(() => {
  vi.clearAllMocks();
  vi.restoreAllMocks();
});

const sha = 'abc1234def5678abc1234def5678abc1234def56';

const armedWatch = {
  id: 'wArmed',
  repository: 'swombat/site',
  event: 'workflow_run',
  filter: { head_sha: sha, workflow_name: 'CI' },
  chat_id: 'chat1',
  chat_title: 'Release room',
  chat_url: '/accounts/house/chats/chat1',
  state: 'armed',
  status: 'armed',
  expires_at: '2026-10-11T12:00:00Z',
  created_by: { type: 'resident', id: 'lume', name: 'Lume' },
  cancel_url: '/accounts/house/watches/wArmed',
};

const fulfilledWatch = {
  id: 'wDone',
  repository: 'swombat/site',
  event: 'deployment_status',
  filter: { environment: 'production' },
  chat_id: 'chat2',
  chat_title: 'Ops',
  chat_url: '/accounts/house/chats/chat2',
  state: 'fulfilled',
  status: 'fulfilled',
  expires_at: '2026-10-11T12:00:00Z',
  fulfilled_at: '2026-10-10T12:00:00Z',
  created_by: { type: 'person', name: 'Daniel' },
  cancel_url: null,
};

const installed = {
  id: 'rInstalled',
  full_name: 'swombat/site',
  hook_status: 'installed',
  hook_error: null,
  last_delivery_at: '2026-10-10T11:00:00Z',
  last_delivery_result: 'verified',
  armed_watches: 1,
  url: '/accounts/house/repositories/rInstalled',
  watches: [armedWatch, fulfilledWatch],
};

const manual = {
  id: 'rManual',
  full_name: 'other/tool',
  hook_status: 'manual',
  hook_error: 'GitHub refused to install the hook (an admin of other/tool must add it)',
  last_delivery_at: null,
  last_delivery_result: null,
  armed_watches: 0,
  url: '/accounts/house/repositories/rManual',
  setup: { url: 'https://house.example.test/webhooks/repositories/tok', secret: 'hook-secret-123' },
  watches: [],
};

const failed = {
  id: 'rFailed',
  full_name: 'other/broken',
  hook_status: 'failed',
  hook_error: 'GitHub answered 422',
  armed_watches: 0,
  url: '/accounts/house/repositories/rFailed',
  watches: [],
};

function connectionWith(attributes) {
  return {
    id: 'svc_7',
    provider: 'github',
    label: 'swombat',
    status: 'connected',
    management_scope: 'personal',
    connected_by_name: 'Daniel',
    can_manage: true,
    can_provision: true,
    can_manage_repositories: true,
    repositories_url: '/accounts/house/repositories',
    repositories: [installed, manual, failed],
    residents: [],
    ...attributes,
  };
}

function mount(attributes = {}) {
  return render(ConnectionRepositories, { connection: connectionWith(attributes) });
}

describe('GitHub card repositories', () => {
  it('lists each repository with its hook status, last delivery and reason', () => {
    mount();
    const site = screen.getByTestId('repository-swombat/site');
    expect(site).toHaveTextContent('Installed');
    expect(site).toHaveTextContent(/Last delivery .*: verified/);
    expect(within(site).queryByTestId('manual-setup')).not.toBeInTheDocument();

    const tool = screen.getByTestId('repository-other/tool');
    expect(tool).toHaveTextContent('Needs manual setup');
    expect(tool).toHaveTextContent('No delivery received yet');

    const broken = screen.getByTestId('repository-other/broken');
    expect(broken).toHaveTextContent('Failed');
    expect(broken).toHaveTextContent('GitHub answered 422');
  });

  it('shows the receiver URL and secret for manual setup to people who can manage the connection', () => {
    mount();
    const setup = within(screen.getByTestId('repository-other/tool')).getByTestId('manual-setup');
    expect(setup).toHaveTextContent('https://house.example.test/webhooks/repositories/tok');
    expect(setup).toHaveTextContent('hook-secret-123');
  });

  it('shows no secret, form or disconnect to a member who cannot manage the connection', () => {
    const { setup, ...withoutSetup } = manual;
    mount({ can_manage_repositories: false, repositories: [installed, withoutSetup] });
    expect(screen.queryByTestId('manual-setup')).not.toBeInTheDocument();
    expect(screen.queryByText('hook-secret-123')).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Disconnect/ })).not.toBeInTheDocument();
    expect(screen.queryByLabelText('Watch a repository')).not.toBeInTheDocument();
    expect(screen.getByText(/Only someone who can manage or provision/)).toBeInTheDocument();
    // Any member may still cancel an armed watch.
    expect(screen.getByRole('button', { name: 'Cancel watch' })).toBeEnabled();
  });

  it('connects a repository by owner/name through the web route', async () => {
    mount();
    const input = screen.getByLabelText('Watch a repository');
    await fireEvent.input(input, { target: { value: '  swombat/new-repo ' } });
    await fireEvent.click(screen.getByRole('button', { name: 'Connect repository' }));
    expect(router.post).toHaveBeenCalledWith(
      '/accounts/house/repositories',
      { service_connection_id: 'svc_7', full_name: 'swombat/new-repo' },
      expect.objectContaining({ preserveScroll: true })
    );
  });

  it('offers no connect form while the connection is not connected', () => {
    mount({ status: 'reauthorizing' });
    expect(screen.queryByLabelText('Watch a repository')).not.toBeInTheDocument();
  });

  it('disconnects a repository after confirmation, and not without it', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValueOnce(false).mockReturnValueOnce(true);
    mount();
    const button = screen.getByRole('button', { name: 'Disconnect swombat/site' });
    await fireEvent.click(button);
    expect(router.delete).not.toHaveBeenCalled();
    await fireEvent.click(button);
    expect(confirm.mock.calls[1][0]).toMatch(/1 armed watch is cancelled/);
    expect(router.delete).toHaveBeenCalledWith('/accounts/house/repositories/rInstalled', expect.anything());
  });

  it('lists watches with state, who armed them, destination, target and expiry', () => {
    mount();
    const watches = screen.getByRole('list', { name: 'Watches on swombat/site' });
    const [armed, done] = within(watches).getAllByRole('listitem');
    expect(armed).toHaveTextContent('CI for abc1234');
    expect(armed).toHaveTextContent('armed');
    expect(armed).toHaveTextContent('Armed by Lume (resident)');
    expect(within(armed).getByRole('link', { name: 'Release room' })).toHaveAttribute(
      'href',
      '/accounts/house/chats/chat1'
    );
    expect(armed).toHaveTextContent(/expires /);
    expect(done).toHaveTextContent('Deployment to production');
    expect(done).toHaveTextContent('fulfilled');
    expect(done).toHaveTextContent('Armed by Daniel');
    expect(within(done).queryByRole('button', { name: 'Cancel watch' })).not.toBeInTheDocument();
  });

  it('says when a watch could not establish its status on GitHub', () => {
    const unknown = { ...armedWatch, status: 'status not established', reconcile_error: 'GitHub unreachable' };
    mount({ repositories: [{ ...installed, watches: [unknown] }] });
    expect(screen.getByText('status not established')).toBeInTheDocument();
    expect(screen.getByText(/Could not establish status on GitHub: GitHub unreachable/)).toBeInTheDocument();
  });

  it('cancels an armed watch after confirmation', async () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    mount();
    await fireEvent.click(screen.getByRole('button', { name: 'Cancel watch' }));
    expect(router.delete).toHaveBeenCalledWith('/accounts/house/watches/wArmed', expect.anything());
  });
});

describe('placement on the integration card', () => {
  it('appears on GitHub connections that carry repositories', () => {
    render(IntegrationConnection, { account: { id: 'house' }, services: [], connection: connectionWith({}) });
    expect(screen.getByRole('heading', { name: 'Repositories' })).toBeInTheDocument();
  });

  it('adds nothing to other providers', () => {
    render(IntegrationConnection, {
      account: { id: 'house' },
      services: [],
      connection: connectionWith({ provider: 'dropbox', repositories: undefined }),
    });
    expect(screen.queryByTestId('repositories')).not.toBeInTheDocument();
  });
});
