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

test('an away seat shows its rhythm count as a link and its running sessions', () => {
  const away = [
    {
      id: 'seat',
      agent: { id: 'lume', name: 'Lume' },
      account: { id: 'dana', name: 'Dana' },
      rhythms: { count: 3, url: '/accounts/dana/rhythms' },
    },
    { id: 'quiet', agent: { id: 'mira', name: 'Mira' }, account: { id: 'dana', name: 'Dana' }, rhythms: { count: 0 } },
  ];
  render(GuestResidents, { accountId: 'home', away, awaySessions: { seat: { chat: 1, telegram: 0, other: 0 } } });
  const rhythms = screen.getAllByTestId('away-rhythms');
  expect(rhythms).toHaveLength(1);
  expect(rhythms[0]).toHaveAttribute('href', '/accounts/dana/rhythms');
  expect(rhythms[0]).toHaveTextContent('3');
  expect(rhythms[0]).toHaveAccessibleName('3 rhythms with Lume in Dana');
  const spinners = screen.getAllByTestId('resident-sessions');
  expect(spinners).toHaveLength(1);
  expect(spinners[0]).toHaveAttribute('data-total', '1');
});

test('an away seat whose account the viewer cannot open shows the count without a link', () => {
  const away = [
    {
      id: 'seat',
      agent: { id: 'lume', name: 'Lume' },
      account: { id: 'x', name: 'X' },
      rhythms: { count: 1, url: null },
    },
  ];
  render(GuestResidents, { accountId: 'home', away });
  const rhythms = screen.getByTestId('away-rhythms');
  expect(rhythms.tagName).toBe('SPAN');
  expect(rhythms).toHaveTextContent('1 rhythm with Lume in X');
});
