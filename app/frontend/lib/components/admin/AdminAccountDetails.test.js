import { render, screen, fireEvent } from '@testing-library/svelte';
import { expect, test } from 'vitest';
import AdminAccountDetails from './AdminAccountDetails.svelte';

const account = {
  id: 'team-one',
  name: 'Test Team',
  account_type: 'team',
  memberships: [],
  created_at: '2026-01-01',
  updated_at: '2026-01-01',
};
const formatDate = (value) => value;

test('keeps the membership draft when a live update refreshes the same account', async () => {
  const { rerender } = render(AdminAccountDetails, { account, formatDate });
  await fireEvent.input(screen.getByLabelText('Existing user email'), { target: { value: 'member@example.com' } });
  await fireEvent.click(screen.getByRole('radio', { name: 'Admin', exact: true }));

  await rerender({ account: { ...account, updated_at: '2026-01-02', users_count: 2 }, formatDate });

  expect(screen.getByLabelText('Existing user email')).toHaveValue('member@example.com');
  expect(screen.getByRole('radio', { name: 'Admin', exact: true })).toHaveAttribute('aria-checked', 'true');
  expect(screen.getByRole('button', { name: 'Add User' })).toBeEnabled();
});

test('clears the membership draft when selecting a different account', async () => {
  const { rerender } = render(AdminAccountDetails, { account, formatDate });
  await fireEvent.input(screen.getByLabelText('Existing user email'), { target: { value: 'member@example.com' } });
  await fireEvent.click(screen.getByRole('radio', { name: 'Admin', exact: true }));

  await rerender({ account: { ...account, id: 'team-two', name: 'Other Team' }, formatDate });

  expect(screen.getByLabelText('Existing user email')).toHaveValue('');
  expect(screen.getByRole('radio', { name: 'Member', exact: true })).toHaveAttribute('aria-checked', 'true');
  expect(screen.getByRole('button', { name: 'Add User' })).toBeDisabled();
});
