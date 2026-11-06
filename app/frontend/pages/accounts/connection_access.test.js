import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import { tick } from 'svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';
import ConnectionAccess from './connection_access.svelte';

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

const account = { id: 'house', name: 'House' };
const resident = (name, enabled) => ({
  id: name,
  name,
  active: true,
  enabled,
  access_update_url: `/accounts/house/agents/${name}/service_accesses/svc_9`,
});

describe('connection access step', () => {
  it('asks who can use a new connection and says nobody can yet', () => {
    render(ConnectionAccess, {
      account,
      connection: {
        id: 'svc_9',
        provider: 'freeagent',
        provider_name: 'FreeAgent',
        label: 'Swombat Limited',
        status: 'connected',
        residents: [resident('Lume', false), resident('Mira', false)],
      },
      integrations_url: '/accounts/house/integrations',
    });
    expect(screen.getByRole('heading', { name: 'Who can use FreeAgent?' })).toBeInTheDocument();
    expect(screen.getByTestId('connection-access-none')).toHaveTextContent('No residents have access yet.');
    expect(screen.getByText('Lume')).toBeInTheDocument();
    expect(screen.getByTestId('connection-access-done')).toHaveTextContent('Skip for now');
  });

  it('offers Done once someone is switched on', () => {
    render(ConnectionAccess, {
      account,
      connection: {
        id: 'svc_9',
        provider: 'freeagent',
        provider_name: 'FreeAgent',
        label: 'Swombat Limited',
        status: 'connected',
        residents: [resident('Lume', true)],
      },
      integrations_url: '/accounts/house/integrations',
    });
    expect(screen.queryByTestId('connection-access-none')).not.toBeInTheDocument();
    expect(screen.getByTestId('connection-access-done')).toHaveTextContent('Done');
    expect(screen.getByTestId('connection-access-done')).toHaveAttribute('href', '/accounts/house/integrations');
  });

  // Mira's round 1 (#811): leaving while a switch is saving could cancel it.
  it('holds Done while a switch is saving, and gives it back when the save lands', async () => {
    let finish;
    const patch = vi.spyOn(router, 'patch').mockImplementation((_url, _data, options) => {
      finish = options.onFinish;
    });
    render(ConnectionAccess, {
      account,
      connection: {
        id: 'svc_9',
        provider: 'freeagent',
        provider_name: 'FreeAgent',
        label: 'Swombat Limited',
        status: 'connected',
        can_provision: true,
        can_manage: true,
        residents: [resident('Lume', false)],
      },
      integrations_url: '/accounts/house/integrations',
    });
    await fireEvent.click(screen.getAllByRole('switch')[0]);
    await tick();
    expect(patch).toHaveBeenCalledWith(
      '/accounts/house/agents/Lume/service_accesses/svc_9',
      { enabled: true },
      expect.anything()
    );
    const held = screen.getByTestId('connection-access-done');
    expect(held).toHaveTextContent('Saving…');
    expect(held).toBeDisabled();
    expect(held).not.toHaveAttribute('href');

    finish();
    await tick();
    expect(screen.getByTestId('connection-access-done')).toHaveAttribute('href', '/accounts/house/integrations');
  });
});
