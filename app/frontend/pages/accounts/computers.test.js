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

const week = (counts) => counts.map((jobs, i) => ({ date: `2026-11-0${i + 1}`, jobs }));

test('a fleet starts as summary cards; the chevron opens one computer’s settings', async () => {
  const second = { ...device, id: 'dev2', name: 'Studio', connected: false, residents: [] };
  render(Computers, { ...props, devices: [device, second] });
  expect(screen.queryByLabelText('Run commands')).not.toBeInTheDocument();
  expect(screen.getByTestId('fleet-summary')).toHaveTextContent('2 computers 1 online now');
  await fireEvent.click(screen.getByRole('button', { name: "Show settings for Daniel's Mac" }));
  expect(screen.getByLabelText('Run commands')).toBeInTheDocument();
  expect(screen.getAllByTestId('computer')[1]).toHaveAttribute('data-status', 'offline');
});

test('the card shows who it serves, the week’s jobs and failures, and disks by kind not by key', () => {
  const busy = {
    ...device,
    activity: { days: week([0, 2, 0, 5, 1, 0, 3]), failed: 2, last_job_at: new Date().toISOString() },
    residents: [{ ...device.residents[0], volumes: [{ volume: 'linux-volume:ed42b0876631aa', access: 'write' }] }],
  };
  render(Computers, { ...props, devices: [busy] });
  expect(screen.getByTestId('computer-access-summary')).toHaveTextContent('Mira');
  expect(screen.getByLabelText('runs commands')).toBeInTheDocument();
  expect(screen.getByText('2 failed')).toBeInTheDocument();
  expect(screen.getByTestId('computer-week-jobs')).toHaveTextContent('11 jobs');
  expect(screen.getByText('just now')).toBeInTheDocument();
  expect(screen.getByText(/Linux disk/)).toBeInTheDocument();
  expect(screen.queryByText('linux-volume:ed42b0876631aa')).not.toBeInTheDocument();
});
