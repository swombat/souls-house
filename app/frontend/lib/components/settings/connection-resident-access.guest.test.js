import { render, screen } from '@testing-library/svelte';
import { describe, expect, it } from 'vitest';
import ConnectionResidentAccess from './connection-resident-access.svelte';
import { accessSummary } from '$lib/connection-summary';

const base = {
  id: 'svc_drive',
  provider: 'google_workspace',
  label: 'anna@example.test',
  status: 'connected',
  can_manage: true,
  can_provision: true,
  residents: [],
};

function guest(attributes) {
  return {
    id: 'lume',
    name: 'Lume',
    guest: true,
    home_account_name: "Daniel's house",
    enabled: false,
    effective: false,
    can_share: true,
    can_withdraw: true,
    access_update_url: '/access/lume',
    ...attributes,
  };
}

describe('sharing a connection with a guest resident', () => {
  it('shows the guest with its home and the sentence about one mind', () => {
    render(ConnectionResidentAccess, { connection: { ...base, residents: [guest()] } });
    expect(screen.getByTestId('guest-badge')).toHaveTextContent("guest · hosted in Daniel's house");
    expect(screen.getByTestId('guest-sharing-note')).toHaveTextContent('one mind');
    expect(screen.getByRole('switch', { name: 'Share anna@example.test with Lume' })).toBeEnabled();
  });

  it('only the owner can share; anyone who manages can withdraw', () => {
    render(ConnectionResidentAccess, {
      connection: {
        ...base,
        residents: [
          guest({ can_share: false }),
          guest({ id: 'mira', name: 'Mira', enabled: true, home_approval: 'pending', can_share: false }),
        ],
      },
    });
    expect(screen.getByRole('switch', { name: 'Share anna@example.test with Lume' })).toBeDisabled();
    expect(screen.getByRole('switch', { name: 'Disable anna@example.test with Mira' })).toBeEnabled();
  });

  it('says where the request stands and counts access only once approved', () => {
    const pending = guest({ enabled: true, home_approval: 'pending' });
    const approved = guest({
      id: 'mira',
      name: 'Mira',
      enabled: true,
      effective: true,
      home_approval: 'approved',
      home_approval_by_name: 'Daniel',
      home_approval_at: '2026-11-01T18:00:00Z',
      provisioning_status: 'provisioned',
    });
    const declined = guest({ id: 'x', name: 'X', home_approval: 'declined' });
    render(ConnectionResidentAccess, { connection: { ...base, residents: [pending, approved, declined] } });
    const statuses = screen.getAllByTestId('guest-approval').map((node) => node.textContent.trim());
    expect(statuses[0]).toBe("Awaiting approval from Lume's home");
    expect(statuses[1]).toMatch(/^Approved by Daniel on /);
    expect(statuses[2]).toBe("Declined by X's home. You can ask again.");
    expect(accessSummary({ residents: [pending, approved, declined] })).toEqual({ text: 'Mira', none: false });
  });
});
