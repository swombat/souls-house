import { render, fireEvent, screen, waitFor } from '@testing-library/svelte';
import { vi } from 'vitest';
vi.mock('$lib/cable', () => ({ subscribeToModel: vi.fn(() => vi.fn()) }));
import { subscribeToModel } from '$lib/cable';
import AgentIndex from './index.svelte';

const candidate = { id: 'visitor', name: 'Visitor', home_account_name: 'Home' };
const props = { account: { id: 'receiving' }, guest_candidates: [candidate] };
const guestProps = ['guest_memberships', 'away_memberships', 'guest_candidates', 'can_end_guest_memberships'];

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

test('same-account refresh preserves selection, but account switch resets it', async () => {
  const component = render(AgentIndex, props);
  await fireEvent.change(screen.getByRole('combobox'), { target: { value: 'visitor' } });
  await component.rerender({ ...props, guest_candidates: [{ ...candidate, name: 'Renamed' }] });
  expect(screen.getByRole('combobox')).toHaveValue('visitor');
  await component.rerender({ ...props, account: { id: 'next' } });
  expect(screen.getByRole('combobox')).toHaveValue('');
});
