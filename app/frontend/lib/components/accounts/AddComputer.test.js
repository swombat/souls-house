import { fireEvent, render, screen } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import AddComputer from './AddComputer.svelte';

const offer = {
  name: "Paulina's Mac",
  volumes: [
    { volume: 'darwin-volume:main', label: 'Main disk', access: 'write' },
    { volume: 'darwin-volume:usb', label: 'Backup', access: 'read' },
  ],
  residents: [{ id: 'nexus', name: 'Claude' }],
};

beforeEach(() => router.post.mockClear?.());
afterEach(() => vi.unstubAllGlobals());

function respond(status, body) {
  vi.stubGlobal(
    'fetch',
    vi.fn(async () => ({ ok: status < 300, status, json: async () => body }))
  );
}

async function enterCode(code) {
  render(AddComputer, { account: { id: 'acct' }, warnings: { write: 'Write warning words.' } });
  await fireEvent.click(screen.getByTestId('add-computer'));
  await fireEvent.input(await screen.findByTestId('pairing-code'), { target: { value: code } });
  await fireEvent.click(screen.getByRole('button', { name: 'Continue' }));
}

test('a code shows the computer, its disks capped at what it offers, and approves what was chosen', async () => {
  respond(200, offer);
  await enterCode('abcd-efgh');
  expect(fetch).toHaveBeenCalledWith(
    '/accounts/acct/computers/pairings/lookup',
    expect.objectContaining({ method: 'POST' })
  );
  expect(await screen.findByTestId('pairing-approve')).toHaveTextContent("Add Paulina's Mac");
  const [main, backup] = screen.getAllByTestId('pairing-access');
  expect([...main.options].map((o) => o.value)).toEqual(['off', 'read', 'write']);
  expect([...backup.options].map((o) => o.value)).toEqual(['off', 'read']);
  await fireEvent.change(main, { target: { value: 'write' } });
  expect(screen.getByText('Write warning words.')).toBeInTheDocument();
  await fireEvent.click(screen.getByTestId('pairing-approve'));
  expect(router.post).toHaveBeenCalledWith(
    '/accounts/acct/computers/pairings',
    {
      code: 'abcd-efgh',
      resident_ids: ['nexus'],
      accesses: { 'darwin-volume:main': 'write', 'darwin-volume:usb': 'read' },
    },
    expect.any(Object)
  );
});

test('an unknown code says so and sends nothing', async () => {
  respond(404, { error: 'No computer is waiting with that code.' });
  await enterCode('ZZZZ-ZZZZ');
  expect(await screen.findByTestId('pairing-error')).toHaveTextContent('No computer is waiting with that code.');
  expect(router.post).not.toHaveBeenCalled();
});
