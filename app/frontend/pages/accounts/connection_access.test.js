import { cleanup, render, screen } from '@testing-library/svelte';
import { afterEach, describe, expect, it } from 'vitest';
import ConnectionAccess from './connection_access.svelte';

afterEach(() => cleanup());

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
});
