import { fireEvent, render, screen, within } from '@testing-library/svelte';
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
  const scope = screen.getByRole('radiogroup', { name: 'Follow-through scope' });
  await fireEvent.click(within(scope).getByRole('radio', { name: 'Chosen residents' }));
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

test('switches billing on for new accounts and says who pays now', async () => {
  render(Settings, {
    setting: { site_name: 'Test House', max_accounts: 30, billing_enabled: false },
    billing: { accounts_required: 2, payment_open: false, configured: true, test_mode: true },
  });
  expect(screen.getByTestId('billing-status')).toHaveTextContent('2 accounts pay for new residents now.');
  expect(screen.getByTestId('billing-status')).toHaveTextContent("those accounts can't create residents");
  expect(screen.getByTestId('billing-status')).toHaveTextContent('Stripe is in test mode.');
  const toggle = screen.getByLabelText('New accounts pay for their residents');
  await fireEvent.click(toggle);
  await fireEvent.submit(toggle.closest('form'));
  const [, body] = router.patch.mock.calls.at(-1);
  expect(body.get('setting[billing_enabled]')).toBe('true');
});

test('turns on scanned-page transcription with a daily ceiling, and says what is sent', async () => {
  render(Settings, {
    setting: {
      site_name: 'Test House',
      max_accounts: 30,
      field_ocr_enabled: false,
      field_ocr_daily_usd_ceiling: '1.0',
    },
    field_ocr: { enabled: false, enabled_at: null, ceiling_usd: '1.0', spent_today: '0.0' },
  });
  expect(screen.getByText(/Only PDFs brought in after it is turned on are sent/)).toBeVisible();
  expect(screen.getByTestId('field-ocr-status')).toHaveTextContent('Spent today: $0.0000.');
  await fireEvent.click(screen.getByLabelText('Transcribe scanned PDF pages'));
  const ceiling = screen.getByLabelText('Most the house spends on it per day (USD)');
  await fireEvent.input(ceiling, { target: { value: '2.5' } });
  await fireEvent.submit(ceiling.closest('form'));
  const [, body] = router.patch.mock.calls.at(-1);
  expect(body.get('setting[field_ocr_enabled]')).toBe('true');
  expect(body.get('setting[field_ocr_daily_usd_ceiling]')).toBe('2.5');
});

test('sets the reflexes scope to one of three states, with no resident picker', async () => {
  render(Settings, {
    setting: { site_name: 'Test House', max_accounts: 30, follow_through_scope: 'off', reflexes_scope: 'disabled' },
    follow_through_residents: [{ id: 'BJZbJx', name: 'Lume', account: 'Daniel', follow_through: true }],
  });
  const reflexScope = screen.getByRole('radiogroup', { name: 'Reflexes scope' });
  expect(
    within(reflexScope)
      .getAllByRole('radio')
      .map((r) => r.textContent.trim())
  ).toEqual(['Disabled', "Account's choice", 'Enabled']);
  expect(screen.getByTestId('reflexes-scope-explain')).toHaveTextContent('whatever an account has chosen');

  await fireEvent.click(within(reflexScope).getByRole('radio', { name: "Account's choice" }));
  expect(screen.getByTestId('reflexes-scope-explain')).toHaveTextContent("Each account's own Reflexes switch decides");
  expect(screen.queryByLabelText('Reflexes for Lume')).toBeNull();
  await fireEvent.submit(reflexScope.closest('form'));
  const [, body] = router.patch.mock.calls.at(-1);
  expect(body.get('setting[reflexes_scope]')).toBe('account_choice');
  expect(body.get('setting[follow_through_scope]')).toBe('off');
  expect(body.has('setting[reflexes_resident_ids][]')).toBe(false);
  expect(body.getAll('setting[follow_through_resident_ids][]')).toEqual(['', 'BJZbJx']);

  await fireEvent.click(within(reflexScope).getByRole('radio', { name: 'Enabled' }));
  expect(within(reflexScope).getByRole('radio', { name: 'Enabled' })).toHaveAttribute('aria-checked', 'true');
  expect(screen.getByTestId('reflexes-scope-explain')).toHaveTextContent("Every resident's posts are checked");
});
