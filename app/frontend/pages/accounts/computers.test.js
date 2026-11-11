import { fireEvent, render, screen } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import { beforeEach, expect, test, vi } from 'vitest';
import Computers from './computers.svelte';

const { syncUpdate } = vi.hoisted(() => ({ syncUpdate: vi.fn() }));
vi.mock('$lib/use-sync', () => ({ createDynamicSync: () => syncUpdate }));

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

const reported = {
  ...device,
  ceiling: {
    reported_at: '2026-11-10T15:00:00Z',
    current: true,
    residents: {
      mira: [
        { volume: 'Data', access: 'write' },
        { volume: 'Photos', access: 'read' },
      ],
    },
  },
};
const withReport = { ...props, devices: [reported], warnings: { ...props.warnings, write: 'Write warning words.' } };

test('without a report from the computer, folders stay read-only and say why', () => {
  render(Computers, props);
  expect(screen.queryByLabelText('Data')).not.toBeInTheDocument();
  expect(screen.getByText(/hasn't said which folders it allows yet/)).toBeInTheDocument();
});

test('with a report, each folder offers no more than the computer allows', () => {
  render(Computers, withReport);
  const photos = screen.getByLabelText('Photos');
  expect(photos).toHaveValue('off');
  expect(photos.querySelector('option[value="read"]')).not.toBeDisabled();
  expect(photos.querySelector('option[value="write"]')).toBeDisabled();
  expect(screen.getByLabelText('Data').querySelector('option[value="write"]')).not.toBeDisabled();
});

test('lowering a folder is sent at once with only that folder', async () => {
  render(Computers, withReport);
  await fireEvent.change(screen.getByLabelText('Data'), { target: { value: 'off' } });
  expect(screen.queryByText('Write warning words.')).not.toBeInTheDocument();
  expect(router.patch).toHaveBeenCalledWith(
    '/accounts/acct/computers/dev1',
    { control: 'volume', resident_id: 'mira', volume: 'Data', access: 'off' },
    expect.any(Object)
  );
});

test('every move into write asks first, and a cancel sends nothing and puts the choice back', async () => {
  render(Computers, withReport);
  await fireEvent.change(screen.getByLabelText('Data'), { target: { value: 'write' } });
  expect(await screen.findByText('Write warning words.')).toBeInTheDocument();
  await fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
  expect(router.patch).not.toHaveBeenCalled();
  expect(screen.getByLabelText('Data')).toHaveValue('read');

  await fireEvent.change(screen.getByLabelText('Data'), { target: { value: 'write' } });
  await fireEvent.click(await screen.findByRole('button', { name: 'Allow' }));
  expect(router.patch).toHaveBeenCalledWith(
    '/accounts/acct/computers/dev1',
    { control: 'volume', resident_id: 'mira', volume: 'Data', access: 'write' },
    expect.any(Object)
  );
});

test('a grant the computer no longer lists can still be lowered, and says so', () => {
  const lowered = {
    ...reported,
    ceiling: { ...reported.ceiling, current: false, residents: { mira: [] } },
  };
  render(Computers, { ...withReport, devices: [lowered] });
  const data = screen.getByLabelText('Data');
  expect(data).toHaveValue('read');
  expect(data.querySelector('option[value="off"]')).not.toBeDisabled();
  expect(data.querySelector('option[value="write"]')).toBeDisabled();
  expect(screen.getByText(/no longer lists this much access/)).toBeInTheDocument();
  expect(screen.getByText(/on an earlier connection; it may have changed since/)).toBeInTheDocument();
});

test('the short disk id shows on every screen size, and a resident with nothing on is not called folders only', () => {
  const idle = {
    ...device,
    residents: [
      { id: 'mira', name: 'Mira', execute: false, desktop: false, volumes: [] },
      {
        id: 'lume',
        name: 'Lume',
        execute: false,
        desktop: false,
        volumes: [{ volume: 'linux-volume:ed42b0876631aa', access: 'read' }],
      },
    ],
  };
  render(Computers, { ...props, devices: [idle] });
  const id = screen.getByText('ed42b087');
  expect(id.className).not.toMatch(/\bhidden\b/);
  const chips = screen.getByTestId('computer-access-summary').querySelectorAll('li');
  expect(chips[0]).toHaveAttribute('title', 'Mira: nothing allowed yet');
  expect(chips[1]).toHaveAttribute('title', 'Lume: folders');
});

test('the write confirmation names the disk, not its raw key', async () => {
  const mac = {
    ...device,
    residents: [{ ...device.residents[0], volumes: [] }],
    ceiling: {
      reported_at: '2026-11-10T15:00:00Z',
      current: true,
      residents: { mira: [{ volume: 'darwin-volume:9a1fe20c77', access: 'write' }] },
    },
  };
  render(Computers, { ...withReport, devices: [mac] });
  await fireEvent.change(screen.getByLabelText(/Mac disk/), { target: { value: 'write' } });
  expect(await screen.findByText("Let Mira write to Mac disk 9a1fe20c on Daniel's Mac?")).toBeInTheDocument();
});

test('the page listens for its computers connecting or dropping and reloads only the devices', () => {
  render(Computers, props);
  expect(syncUpdate).toHaveBeenLastCalledWith({ 'ComputerStatus:acct': ['devices'] });
});
