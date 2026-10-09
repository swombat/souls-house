import { fireEvent, render, screen } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import Settings from './settings.svelte';

vi.mock('$lib/use-sync', () => ({ useSync: vi.fn() }));

test('edits the system account cap and sends it to the admin endpoint', async () => {
  render(Settings, { setting: { site_name: 'Test House', max_accounts: 30 } });
  const input = screen.getByLabelText('Maximum accounts');
  expect(input).toHaveValue(30);
  expect(input).toHaveAttribute('min', '0');
  expect(screen.getByText(/including disabled accounts/)).toBeVisible();
  await fireEvent.input(input, { target: { value: '42' } });
  await fireEvent.submit(input.closest('form'));
  expect(router.patch).toHaveBeenCalled();
  const [url, body] = router.patch.mock.calls.at(-1);
  expect(url).toBe('/admin/settings');
  expect(body.get('setting[max_accounts]')).toBe('42');
});

test('picks follow-through residents from a searchable list', async () => {
  render(Settings, {
    setting: { site_name: 'Test House', max_accounts: 30, follow_through_scope: 'off' },
    follow_through_residents: [
      { id: 'BJZbJx', name: 'Lume', account: 'Daniel', follow_through: true },
      { id: 'AYawJx', name: 'Mira', account: 'Daniel', follow_through: false },
      { id: 'QQqqQQ', name: 'Wing', account: 'Paulina', follow_through: false, paused: true },
    ],
  });
  expect(screen.queryByLabelText('Follow-through for Lume')).toBeNull();
  await fireEvent.click(screen.getByRole('radio', { name: 'Chosen residents' }));
  expect(screen.getByText('1 of 3 chosen')).toBeVisible();
  expect(screen.getByText('(paused)')).toBeVisible();

  await fireEvent.input(screen.getByLabelText('Find a resident'), { target: { value: 'mir' } });
  expect(screen.queryByLabelText('Follow-through for Wing')).toBeNull();
  await fireEvent.click(screen.getByLabelText('Follow-through for Mira'));
  expect(screen.getByText('2 of 3 chosen')).toBeVisible();

  await fireEvent.submit(screen.getByLabelText('Find a resident').closest('form'));
  const [, body] = router.patch.mock.calls.at(-1);
  expect(body.get('setting[follow_through_scope]')).toBe('selected');
  expect(body.getAll('setting[follow_through_resident_ids][]')).toEqual(['', 'BJZbJx', 'AYawJx']);
});

test('switches new residents onto their own server with a cap and shows the exclusions', async () => {
  render(Settings, {
    setting: { site_name: 'Test House', max_accounts: 30, new_residents_on_vm: false, vm_resident_limit: 0 },
    vm_births: { enabled: false, limit: 0, vm_count: 1, procurement_configured: true, birth_refusal: null },
  });
  expect(screen.getByTestId('vm-birth-exclusions')).toHaveTextContent('imported residents');
  expect(screen.getByText(/1 counted now/)).toBeVisible();
  await fireEvent.click(screen.getByLabelText('New residents on their own server'));
  const limit = screen.getByLabelText('Most resident servers at once');
  await fireEvent.input(limit, { target: { value: '2' } });
  await fireEvent.submit(limit.closest('form'));
  const [, body] = router.patch.mock.calls.at(-1);
  expect(body.get('setting[new_residents_on_vm]')).toBe('true');
  expect(body.get('setting[vm_resident_limit]')).toBe('2');
});

test('says plainly when the switch is on and births are being refused', () => {
  render(Settings, {
    setting: { site_name: 'Test House', max_accounts: 30, new_residents_on_vm: true, vm_resident_limit: 1 },
    vm_births: { enabled: true, procurement_configured: true, birth_refusal: "that isn't available yet" },
  });
  expect(screen.getByTestId('vm-birth-status')).toHaveTextContent(
    "New residents are being refused: that isn't available yet"
  );
});
