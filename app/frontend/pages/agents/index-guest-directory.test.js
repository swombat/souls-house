import { render, fireEvent, screen, waitFor } from '@testing-library/svelte';
import { vi } from 'vitest';
vi.mock('@inertiajs/svelte', async (importOriginal) => ({
  ...(await importOriginal()),
  page: (await import('svelte/store')).writable({ props: {} }),
}));
vi.mock('$lib/cable', () => ({ subscribeToModel: vi.fn(() => vi.fn()) }));
import { page } from '@inertiajs/svelte';
import { subscribeToModel } from '$lib/cable';
import AgentIndex from './index.svelte';

const candidate = { id: 'visitor', name: 'Visitor', home_account_name: 'Home' };
const props = { account: { id: 'receiving' }, guest_candidates: [candidate] };
const guestProps = ['guest_memberships', 'away_memberships', 'guest_candidates', 'can_end_guest_memberships'];

beforeEach(() => page.set({ props: {} }));

test('an empty directory subscribes narrowly and switches with the current account', async () => {
  const component = render(AgentIndex, { account: props.account });
  await waitFor(() => expect(subscribeToModel).toHaveBeenCalledWith('GuestDirectory', 'receiving', guestProps));
  expect(subscribeToModel).not.toHaveBeenCalledWith('GuestDiscovery', expect.anything(), expect.anything());
  const count = subscribeToModel.mock.calls.length;
  await component.rerender({ account: { id: 'receiving' }, guest_memberships: [] });
  expect(subscribeToModel).toHaveBeenCalledTimes(count);
  const oldCleanups = subscribeToModel.mock.results.map((result) => result.value);
  await component.rerender({ account: { id: 'next' } });
  await waitFor(() => expect(subscribeToModel).toHaveBeenCalledWith('GuestDirectory', 'next', guestProps));
  oldCleanups.forEach((cleanup) => expect(cleanup).toHaveBeenCalledOnce());
});

test('candidate discovery uses only the current human and survives account switches without subscribing to homes', async () => {
  page.set({ props: { user: { id: 'self' } } });
  const component = render(AgentIndex, props);
  await waitFor(() => expect(subscribeToModel).toHaveBeenCalledWith('GuestDiscovery', 'self', ['guest_candidates']));
  const selfCleanup =
    subscribeToModel.mock.results[subscribeToModel.mock.calls.findIndex(([model]) => model === 'GuestDiscovery')].value;
  await component.rerender({ ...props, account: { id: 'next' } });
  await waitFor(() => expect(subscribeToModel).toHaveBeenCalledWith('GuestDirectory', 'next', guestProps));
  expect(selfCleanup).not.toHaveBeenCalled();
  expect(subscribeToModel.mock.calls.filter(([model]) => model === 'GuestDiscovery')).toHaveLength(1);
  expect(
    subscribeToModel.mock.calls.every(([model]) => ['Account', 'GuestDirectory', 'GuestDiscovery'].includes(model))
  ).toBe(true);
  page.set({ props: { user: { id: 'new-self' } } });
  await waitFor(() =>
    expect(subscribeToModel).toHaveBeenCalledWith('GuestDiscovery', 'new-self', ['guest_candidates'])
  );
  expect(selfCleanup).toHaveBeenCalledOnce();
  page.set({ props: {} });
  const newCleanup = subscribeToModel.mock.results.at(-1).value;
  await waitFor(() => expect(newCleanup).toHaveBeenCalledOnce());
});

test('a no-longer-eligible candidate clears the choice without remounting the page', async () => {
  const component = render(AgentIndex, props);
  await fireEvent.change(screen.getByRole('combobox'), { target: { value: 'visitor' } });
  await component.rerender({ ...props, guest_candidates: [{ id: 'different', name: 'Other' }] });
  expect(screen.getByRole('combobox')).toHaveValue('');
  expect(screen.getByRole('button', { name: 'Add as guest' })).toBeDisabled();
});

test('same-account refresh preserves selection, but account switch resets it', async () => {
  const component = render(AgentIndex, props);
  await fireEvent.change(screen.getByRole('combobox'), { target: { value: 'visitor' } });
  await component.rerender({ ...props, guest_candidates: [{ ...candidate, name: 'Renamed' }] });
  expect(screen.getByRole('combobox')).toHaveValue('visitor');
  await component.rerender({ ...props, account: { id: 'next' } });
  expect(screen.getByRole('combobox')).toHaveValue('');
});
