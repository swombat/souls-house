import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { vi } from 'vitest';

const postJson = vi.fn();
vi.mock('$lib/stripe', () => ({
  loadStripe: vi.fn(),
  createEmbeddedCheckout: vi.fn(),
  postJson: (...args) => postJson(...args),
}));

const { default: PlanStep } = await import('./plan-step.svelte');

const billing = {
  can_pay: true,
  publishable_key: 'pk_test_1',
  tiers: [
    {
      id: 'conversation',
      name: 'Small',
      size: 'small',
      monthly_usd: '9.99',
      allowance_usd: '10.00',
      purchasable: true,
    },
  ],
  payment_method: { brand: 'visa', last4: '4242', exp_month: 1, exp_year: 2030 },
  contact_email: 'hello@example.com',
  birth_orders_url: '/accounts/a/birth_orders',
};
const quote = {
  added_cents: 1200,
  next_total_cents: 3400,
  recurring_cents: 2200,
  currency: 'usd',
  next_at: '2026-12-01',
  digest: 'd1',
};
const itemPayment = {
  order: { id: 'o2', kind: 'item', state: 'pending', resident_name: 'Aria' },
  item_quote: quote,
  confirm_item_url: '/accounts/a/birth_orders/o2/confirm_item',
  payment_url: '/accounts/a/birth_orders/o2/payment',
  confirm_url: '/accounts/a/birth_orders/o2/confirm',
};

beforeEach(() => postJson.mockReset());

test('an account that adds to its bill shows no card terms, even before a quote', () => {
  render(PlanStep, { billing: { ...billing, adds_to_bill: true }, residentName: 'Aria', tier: 'conversation' });
  expect(screen.queryByText(/Today:/)).toBeNull();
  expect(screen.queryByText(/first month/)).toBeNull();
});

test('shows no panel without an item order', () => {
  render(PlanStep, { billing, residentName: 'Aria' });
  expect(screen.queryByTestId('birth-add-confirm')).toBeNull();
});

test('shows the quote, charges nothing, and posts the digest on confirm', async () => {
  postJson
    .mockResolvedValueOnce({ order: itemPayment.order, accepted: true })
    .mockResolvedValueOnce({ order: { state: 'born' }, redirect_to: '/born' });
  const onconfirmed = vi.fn();
  render(PlanStep, { billing, residentName: 'Aria', itemPayment, onconfirmed });

  const panel = screen.getByTestId('birth-add-confirm');
  expect(panel).toHaveTextContent('Nothing is charged today.');
  expect(panel).toHaveTextContent('Your next bill, on 2026-12-01, goes up by about $12.00 for Aria');
  expect(panel).toHaveTextContent('comes to about $34.00 in all');
  expect(panel).toHaveTextContent('the account pays about $22.00 a month');
  expect(panel).toHaveTextContent("These are Stripe's totals, with tax and discounts in.");

  await fireEvent.click(screen.getByRole('button', { name: "Create Aria and add to the account's bill" }));

  await waitFor(() => expect(onconfirmed).toHaveBeenCalledWith(expect.objectContaining({ redirectTo: '/born' })));
  expect(postJson).toHaveBeenNthCalledWith(1, itemPayment.confirm_item_url, { digest: 'd1' });
});

test('a changed price replaces the quote and says nothing was charged', async () => {
  postJson.mockRejectedValueOnce(
    Object.assign(new Error('The price changed.'), {
      data: { error: 'The price changed.', item_quote: { ...quote, added_cents: 1500, digest: 'd2' } },
    })
  );
  const onconfirmfailed = vi.fn();
  render(PlanStep, { billing, residentName: 'Aria', itemPayment, onconfirmfailed });

  await fireEvent.click(screen.getByRole('button', { name: /add to the account's bill/ }));

  await waitFor(() =>
    expect(screen.getByTestId('birth-add-changed')).toHaveTextContent(
      'The price changed since it was shown. Here is the new one; nothing was charged.'
    )
  );
  expect(screen.getByTestId('birth-add-confirm')).toHaveTextContent('goes up by about $15.00');
  expect(onconfirmfailed).toHaveBeenCalled();
});

test('Not now dismisses without posting anything', async () => {
  const ondismiss = vi.fn();
  render(PlanStep, { billing, residentName: 'Aria', itemPayment, ondismiss });

  await fireEvent.click(screen.getByRole('button', { name: 'Not now' }));

  expect(ondismiss).toHaveBeenCalled();
  expect(postJson).not.toHaveBeenCalled();
});

test('a failure on a deferred order never talks about a declined card', () => {
  render(PlanStep, { billing, residentName: 'Aria', deferred: true, payError: 'Something happened.' });
  const alert = screen.getByTestId('plan-pay-error');
  expect(alert).toHaveTextContent('Something happened.');
  expect(alert).not.toHaveTextContent(/payment didn't go through|different card/);
});
