import { render, screen } from '@testing-library/svelte';
import BillingSettingsCard from './BillingSettingsCard.svelte';

const base = {
  accounts_required: 1,
  payment_open: true,
  configured: true,
  test_mode: true,
  stripe_events_failed: 0,
  stripe_events_last_error: null,
  ungranted_subscriptions: 0,
};

test('a mixed portal result shows the unsafe price and the unreadable configuration, both', () => {
  render(BillingSettingsCard, {
    form: { billing_enabled: true },
    status: {
      ...base,
      portal: {
        checked_at: '2026-10-28T17:00:00Z',
        switchable_prices: ['price_life_at_cost'],
        at_cost_switchable: ['price_life_at_cost'],
        unknown_configurations: ['bpc_2'],
      },
    },
  });

  expect(screen.getByTestId('portal-unsafe')).toHaveTextContent('price_life_at_cost');
  expect(screen.getByTestId('portal-unknown')).toHaveTextContent('bpc_2');
  expect(screen.queryByTestId('portal-clean')).toBeNull();
});

test('with nothing wrong the card says so, in plain words', () => {
  render(BillingSettingsCard, {
    form: { billing_enabled: true },
    status: { ...base, portal: { checked_at: '2026-10-28T17:00:00Z', switchable_prices: [], at_cost_switchable: [] } },
  });

  expect(screen.getByTestId('portal-clean')).toHaveTextContent('lets nobody switch plans');
  expect(screen.getByText('Every Stripe event of the last 7 days was applied.')).toBeVisible();
  expect(screen.getByText('No at-cost subscription without a code grant in the last 30 days.')).toBeVisible();
});

test('a failed check is a failure, not a clean portal', () => {
  render(BillingSettingsCard, {
    form: { billing_enabled: true },
    status: { ...base, portal: { checked_at: '2026-10-28T17:00:00Z', error: 'no route to Stripe' } },
  });

  expect(screen.getByTestId('portal-error')).toHaveTextContent('no route to Stripe');
  expect(screen.queryByTestId('portal-clean')).toBeNull();
});
