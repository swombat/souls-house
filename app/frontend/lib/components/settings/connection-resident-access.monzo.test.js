import { render, screen } from '@testing-library/svelte';
import { describe, expect, it } from 'vitest';
import ConnectionResidentAccess from './connection-resident-access.svelte';

const base = {
  id: 'svc_monzo',
  provider: 'monzo',
  label: 'daniel@example.test',
  status: 'connected',
  can_manage: true,
  can_provision: true,
  residents: [],
};

describe('granting residents a Monzo connection', () => {
  it('reminds the person to approve access in the Monzo app', () => {
    render(ConnectionResidentAccess, { connection: base });
    expect(screen.getByTestId('monzo-app-approval-note')).toHaveTextContent('approve access in the Monzo app');
  });

  it('says nothing of Monzo for other providers', () => {
    render(ConnectionResidentAccess, { connection: { ...base, provider: 'xero' } });
    expect(screen.queryByTestId('monzo-app-approval-note')).toBeNull();
  });
});
