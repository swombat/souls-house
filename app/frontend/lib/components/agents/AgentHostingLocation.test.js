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
