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

const trialing = { ...paid, subscription: { ...paid.subscription, status: 'trialing' } };

test('a resident on its free trial says until when, and how to keep it, true with or without a card', async () => {
  const onmanage = vi.fn();
  render(ResidentBillingNote, {
    resident: { id: 'r', name: 'Aria', entitlement: trialing, trial_ends_at: '2026-11-24T12:00:00Z' },
    price: '$9.99 a month',
    trial: true,
    canManage: true,
    onmanage,
  });
  const note = screen.getByTestId('resident-trial');
  expect(note).toHaveTextContent(
    'Free trial until 24 Nov 2026. Add a card from Manage billing to keep Aria awake after 24 Nov 2026 at $9.99 a ' +
      'month + VAT; with no card, Aria goes to sleep on 24 Nov 2026 and nothing is deleted.'
  );
  expect(note.textContent).not.toMatch(/—/);
  expect(screen.queryByText(/Renews on/)).toBeNull();
  await fireEvent.click(screen.getByRole('button', { name: 'Manage billing' }));
  expect(onmanage).toHaveBeenCalled();
});

test('has_payment_method is not read: a trial reads the same whatever it says', () => {
  render(ResidentBillingNote, {
    resident: {
      id: 'r',
      name: 'Aria',
      entitlement: trialing,
      trial_ends_at: '2026-11-24T12:00:00Z',
      has_payment_method: true,
    },
    price: '$9.99 a month',
    trial: true,
  });
  expect(screen.getByTestId('resident-trial')).toHaveTextContent('Add a card from Manage billing to keep Aria awake');
  expect(screen.queryByText(/card on file/)).toBeNull();
  expect(screen.queryByRole('button', { name: 'Manage billing' })).toBeNull();
});

test('during the trial the allowance is $10 for the trial, not a month', () => {
  const entitlement = { ...trialing, subscription: { ...trialing.subscription, includes_allowance: true } };
  render(ResidentBillingNote, {
    resident: { id: 'r', name: 'Aria', entitlement, trial_ends_at: '2026-11-24T12:00:00Z' },
    trial: true,
  });
  expect(screen.getByTestId('resident-allowance')).toHaveTextContent(
    "Carries the account's $10 of house-model use for the free trial, until 24 Nov 2026."
  );
  expect(screen.getByTestId('resident-allowance')).not.toHaveTextContent('a month');
});

test('a trialing subscription without trial_ends_at in the props still reads sensibly', () => {
  render(ResidentBillingNote, { resident: { id: 'r', name: 'Aria', entitlement: trialing }, trial: true });
  expect(screen.getByTestId('resident-trial')).toHaveTextContent(
    'On its free trial. Add a card from Manage billing to keep Aria awake after the trial; with no card, Aria goes to ' +
      'sleep then and nothing is deleted.'
  );
});
