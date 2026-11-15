import { render, screen } from '@testing-library/svelte';
import { expect, test } from 'vitest';
import AgentHostingLocation from './AgentHostingLocation.svelte';

test('a VM resident shows the Hetzner server type, its size and where it is', () => {
  render(AgentHostingLocation, {
    hostingLocation: {
      kind: 'vm',
      status: 'ready',
      server_type: 'CX23',
      vcpus: 2,
      ram_gb: 4,
      disk_gb: 40,
      location: 'Falkenstein, Germany',
    },
  });
  const block = screen.getByTestId('hosting-location');
  expect(block).toHaveTextContent(
    'On its own server: a Hetzner Cloud CX23 (2 vCPUs, 4 GB RAM, 40 GB disk), in Falkenstein, Germany.'
  );
  expect(block).not.toHaveTextContent('still being set up');
  expect(block).not.toHaveTextContent('signed up early');
});

test('a VM being bought says so', () => {
  render(AgentHostingLocation, { hostingLocation: { kind: 'vm', status: 'pending', server_type: 'CX33' } });
  expect(screen.getByText('The server is still being set up.')).toBeInTheDocument();
});

test('a house resident is on the main server, free for early sign-ups, with the fair-use note', () => {
  render(AgentHostingLocation, { hostingLocation: { kind: 'house' } });
  const block = screen.getByTestId('hosting-location');
  expect(block).toHaveTextContent(/Directly on the main .+ server, shared with other residents\./);
  expect(block).toHaveTextContent('free of charge for people who signed up early');
  expect(block).toHaveTextContent('move their residents onto their own VMs');
  expect(block).not.toHaveTextContent('Hetzner');
});

test('an import waiting to move says nothing has been bought, not that it is being set up', () => {
  render(AgentHostingLocation, { hostingLocation: { kind: 'vm', status: 'staged' } });
  const block = screen.getByTestId('hosting-location');
  expect(block).toHaveTextContent('Waiting to move onto its own server.');
  expect(block).not.toHaveTextContent('Hetzner');
  expect(block).not.toHaveTextContent('being set up');
});

test('a resident on no server says so, and does not claim the main server', () => {
  render(AgentHostingLocation, { hostingLocation: { kind: 'none' } });
  const block = screen.getByTestId('hosting-location');
  expect(block).toHaveTextContent('Not on any server right now');
  expect(block).not.toHaveTextContent('Directly on the main');
  expect(block).not.toHaveTextContent('On its own server');
});

test('a failed setup says so without claiming the server is gone', () => {
  render(AgentHostingLocation, { hostingLocation: { kind: 'failed' } });
  const block = screen.getByTestId('hosting-location');
  expect(block).toHaveTextContent('Setting up its own server failed. Cleaning up that server may still be pending.');
  expect(block).not.toHaveTextContent('Not on any server');
  expect(block).not.toHaveTextContent('Directly on the main');
});

test('the backups kept, their age and the space they take are shown', () => {
  render(AgentHostingLocation, {
    hostingLocation: {
      kind: 'house',
      backups: {
        snapshots: 9,
        oldest_at: '2026-11-06T04:10:00Z',
        stored_bytes: 13 * 1024 ** 3,
        space_bytes: 60 * 1024 ** 3,
        thinned_to_fit: false,
        over_space: false,
      },
    },
  });
  const block = screen.getByTestId('backup-history');
  expect(block).toHaveTextContent('9 backups are kept');
  expect(block).toHaveTextContent("13.0 GB of this resident's 60.0 GB of backup space");
  expect(screen.queryByTestId('backup-thinned')).toBeNull();
});

test('history being thinned to fit is said, and so is a newest backup larger than the space', () => {
  const backups = { snapshots: 1, stored_bytes: 70 * 1024 ** 3, space_bytes: 60 * 1024 ** 3 };
  const { unmount } = render(AgentHostingLocation, {
    hostingLocation: { kind: 'vm', status: 'ready', backups: { ...backups, thinned_to_fit: true, over_space: false } },
  });
  expect(screen.getByTestId('backup-thinned')).toHaveTextContent('Older backups are being removed');
  expect(screen.getByTestId('backup-history')).toHaveTextContent('1 backup is kept');
  unmount();

  render(AgentHostingLocation, {
    hostingLocation: { kind: 'vm', status: 'ready', backups: { ...backups, thinned_to_fit: true, over_space: true } },
  });
  expect(screen.getByTestId('backup-over-space')).toHaveTextContent('for the house to fix');
});

test('no backup line before the house has read the repository', () => {
  render(AgentHostingLocation, { hostingLocation: { kind: 'house', backups: null } });
  expect(screen.queryByTestId('backup-history')).toBeNull();
});
