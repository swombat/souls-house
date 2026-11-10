import { fireEvent, render, screen } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import { beforeEach, expect, test } from 'vitest';
import Computers from './computers.svelte';

const device = {
  id: 'dev1',
  name: "Daniel's Mac",
  paused: false,
  connected: true,
  residents: [
    { id: 'mira', name: 'Mira', execute: true, desktop: false, volumes: [{ volume: 'Data', access: 'read' }] },
  ],
};
const props = {
  account: { id: 'acct', name: 'Home' },
  can_manage: true,
  devices: [device],
  warnings: { execute: 'Execute warning words.', desktop: 'Desktop warning words.' },
};

beforeEach(() => router.patch.mockClear());

test('turning desktop on asks first, shows the warning, and a cancel sends nothing', async () => {
  render(Computers, props);
  const desktop = screen.getByLabelText('Use apps (desktop)');
  await fireEvent.click(desktop);
  expect(await screen.findByText('Desktop warning words.')).toBeInTheDocument();
  expect(screen.getByText("Let Mira use apps on Daniel's Mac?")).toBeInTheDocument();
  await fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
  expect(router.patch).not.toHaveBeenCalled();
  expect(screen.getAllByRole('switch', { hidden: true })[1]).toHaveAttribute('aria-checked', 'false');
});

test('allowing sends only the switch that was turned on', async () => {
  render(Computers, props);
  await fireEvent.click(screen.getByLabelText('Use apps (desktop)'));
  await fireEvent.click(await screen.findByRole('button', { name: 'Allow' }));
  expect(router.patch).toHaveBeenCalledWith(
    '/accounts/acct/computers/dev1',
    { control: 'authority', resident_id: 'mira', permission: 'desktop', value: true },
    expect.any(Object)
  );
});

test('turning a power off needs no confirmation', async () => {
  render(Computers, props);
  await fireEvent.click(screen.getByLabelText('Run commands'));
  expect(screen.queryByText('Execute warning words.')).not.toBeInTheDocument();
  expect(router.patch).toHaveBeenCalledWith(
    '/accounts/acct/computers/dev1',
    { control: 'authority', resident_id: 'mira', permission: 'execute', value: false },
    expect.any(Object)
  );
});

test('a member without admin rights sees the computer but cannot change it', () => {
  render(Computers, { ...props, can_manage: false });
  expect(screen.getByText("Daniel's Mac")).toBeInTheDocument();
  expect(screen.getByText('Data')).toBeInTheDocument();
  expect(screen.getByLabelText('Run commands')).toBeDisabled();
  expect(screen.queryByRole('button', { name: /Pause/ })).not.toBeInTheDocument();
});
