import { render, screen, fireEvent } from '@testing-library/svelte';
import { vi } from 'vitest';
import ResidentBillingNote from './ResidentBillingNote.svelte';

const paid = {
  state: 'active',
  source: 'stripe',
  tier: 'conversation',
  rate: 'standard',
  subscription: {
    status: 'active',
    tier: 'conversation',
    rate: 'standard',
    current_period_end: '2026-12-10T00:00:00Z',
    cancel_at_period_end: false,
  },
};

test('a paid resident says when it renews', () => {
  render(ResidentBillingNote, { resident: { id: 'r', name: 'Aria', entitlement: paid }, price: '$9.99 a month' });
  expect(screen.getByText('Renews on 10 Dec 2026.')).toBeVisible();
  expect(screen.queryByTestId('resident-trial')).toBeNull();
  expect(screen.queryByTestId('resident-allowance')).toBeNull();
});

test('the resident that carries the allowance says so', () => {
  const entitlement = { ...paid, subscription: { ...paid.subscription, includes_allowance: true } };
  render(ResidentBillingNote, { resident: { id: 'r', name: 'Aria', entitlement } });
  expect(screen.getByTestId('resident-allowance')).toHaveTextContent(
    "Carries the account's $10 a month of house-model use."
  );
});

test('a resident in its free 14 days with no card says when it sleeps, and links to Manage billing', async () => {
  const onmanage = vi.fn();
  const entitlement = { ...paid, subscription: { ...paid.subscription, status: 'trialing' } };
  render(ResidentBillingNote, {
    resident: { id: 'r', name: 'Aria', entitlement, trial_ends_at: '2026-11-24T12:00:00Z' },
    price: '$9.99 a month',
    trial: true,
    canManage: true,
    onmanage,
  });
  const note = screen.getByTestId('resident-trial');
  expect(note).toHaveTextContent('Free until 24 Nov 2026.');
  expect(note).toHaveTextContent('Add a card to keep Aria awake after 24 Nov 2026.');
  expect(note).toHaveTextContent('Nothing is deleted.');
  expect(screen.queryByText(/Renews on/)).toBeNull();
  await fireEvent.click(screen.getByRole('button', { name: 'Manage billing' }));
  expect(onmanage).toHaveBeenCalled();
});

test('a resident in its free 14 days with a card says what follows', () => {
  render(ResidentBillingNote, {
    resident: {
      id: 'r',
      name: 'Aria',
      entitlement: paid,
      trial_ends_at: '2026-11-24T12:00:00Z',
      has_payment_method: true,
    },
    price: '$9.99 a month',
    trial: true,
    canManage: true,
  });
  expect(screen.getByTestId('resident-trial')).toHaveTextContent(
    'Free until 24 Nov 2026. Then $9.99 a month + VAT on the card on file.'
  );
  expect(screen.queryByRole('button', { name: 'Manage billing' })).toBeNull();
});

test('a trialing subscription without trial_ends_at in the props still reads sensibly', () => {
  const entitlement = { ...paid, subscription: { ...paid.subscription, status: 'trialing' } };
  render(ResidentBillingNote, { resident: { id: 'r', name: 'Aria', entitlement }, trial: true, canManage: true });
  expect(screen.getByTestId('resident-trial')).toHaveTextContent('In its free 14 days.');
  expect(screen.queryByText(/Add a card/)).toBeNull();
});
