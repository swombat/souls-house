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

test('edits the follow-through residents and shows who each id is', async () => {
  render(Settings, {
    setting: { site_name: 'Test House', max_accounts: 30, follow_through_residents: 'BJZbJx, zzz' },
    follow_through_residents: [
      { id: 'BJZbJx', name: 'Lume', account: 'Daniel' },
      { id: 'zzz', name: null, account: null },
    ],
  });
  const input = screen.getByLabelText('Follow-through check');
  expect(input).toHaveValue('BJZbJx, zzz');
  expect(screen.getByText(/Lume \(Daniel\)/)).toBeVisible();
  expect(screen.getByText('no resident with this id')).toBeVisible();
  await fireEvent.input(input, { target: { value: 'all' } });
  await fireEvent.submit(input.closest('form'));
  const [, body] = router.patch.mock.calls.at(-1);
  expect(body.get('setting[follow_through_residents]')).toBe('all');
});
