import { render, fireEvent, screen, waitFor } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import GuestResidents from './guest-residents.svelte';

const candidate = { id: 'visitor', name: 'Visitor', home_account_name: 'Home' };
const props = { accountId: 'receiving', candidates: [candidate] };

test('directory refresh preserves a still-eligible selection', async () => {
  const component = render(GuestResidents, props);
  const select = screen.getByRole('combobox');
  await fireEvent.change(select, { target: { value: 'visitor' } });
  await component.rerender({ ...props, candidates: [{ ...candidate, name: 'Renamed' }], canEnd: true });
  expect(select).toHaveValue('visitor');
  await fireEvent.click(screen.getByRole('button', { name: 'Add as guest' }));
  expect(router.post).toHaveBeenCalledWith(
    '/accounts/receiving/guest_memberships',
    { agent_id: 'visitor' },
    expect.any(Object)
  );
});

test('a disappearing candidate clears the old selection and cannot be submitted', async () => {
  const component = render(GuestResidents, props);
  await fireEvent.change(screen.getByRole('combobox'), { target: { value: 'visitor' } });
  await component.rerender({ ...props, candidates: [{ ...candidate, id: 'other' }] });
  await waitFor(() => expect(screen.getByRole('combobox')).toHaveValue(''));
  expect(screen.getByRole('button', { name: 'Add as guest' })).toBeDisabled();
  expect(router.post).not.toHaveBeenCalled();
});

test('removal controls follow live permission while keeping the directory visible', async () => {
  const guests = [{ id: 'membership', agent: candidate, home_account: { name: 'Home' } }];
  const component = render(GuestResidents, { ...props, guests, canEnd: true });
  expect(screen.getByRole('button', { name: 'Remove' })).toBeVisible();
  await component.rerender({ ...props, guests, canEnd: false });
  expect(screen.queryByRole('button', { name: 'Remove' })).not.toBeInTheDocument();
  expect(screen.getByTestId('guest-residents')).toHaveTextContent('Visitor');
});
