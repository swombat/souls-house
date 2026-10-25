import { render, screen } from '@testing-library/svelte';
import PlanStep from './plan-step.svelte';

const tiers = [
  {
    id: 'conversation',
    name: 'Conversation',
    monthly_usd: 20,
    purchasable: true,
    features: {
      vcpus: 2,
      ram_gb: 4,
      disk_gb: 40,
      allowance_usd: 8,
      transcription_hours: 5,
      backup_gb: 10,
      connections: [],
    },
  },
  {
    id: 'life',
    name: 'Life',
    monthly_usd: 50,
    purchasable: true,
    features: {
      vcpus: 4,
      ram_gb: 8,
      disk_gb: 80,
      allowance_usd: 25,
      transcription_hours: 20,
      backup_gb: 50,
      connections: ['x'],
    },
  },
];
const billing = {
  can_pay: true,
  test_mode: true,
  publishable_key: 'pk_test_1',
  tiers,
  payment_method: null,
  contact_email: 'hello@example.com',
  card_setup_url: '/accounts/a/billing_card',
  card_setup_complete_url: '/accounts/a/billing_card/complete',
  birth_orders_url: '/accounts/a/birth_orders',
};

test('offers each plan with its price, preselects the first, and states the terms plainly', () => {
  render(PlanStep, { billing, residentName: 'Aria' });

  expect(screen.getByText('A plan for Aria')).toBeVisible();
  expect(screen.getByRole('radio', { name: /Conversation/ })).toBeChecked();
  expect(screen.getByRole('radio', { name: /Life/ })).not.toBeChecked();
  expect(screen.getByText('Someone to talk with.')).toBeVisible();
  expect(screen.getByText('$8 a month of house model')).toBeVisible();
  const terms = screen.getByTestId('plan-terms');
  expect(terms).toHaveTextContent("Today: $20 + VAT for Aria's first month.");
  expect(terms).toHaveTextContent('Then $20 + VAT each month until you cancel.');
  expect(terms).toHaveTextContent('within 30 days for a full refund');
  expect(screen.getByTestId('plan-test-mode')).toHaveTextContent('4242 4242 4242 4242');
});

test('without a card on file it asks for one, and says nothing is charged yet', () => {
  render(PlanStep, { billing, residentName: 'Aria' });
  expect(screen.getByRole('button', { name: 'Add a card' })).toBeVisible();
  expect(screen.getByText(/isn't charged until you create Aria/)).toBeVisible();
});

test('with a card on file it is a confirmation, with a way to change the card', () => {
  render(PlanStep, {
    billing,
    residentName: 'Aria',
    paymentMethod: { brand: 'visa', last4: '4242', exp_month: 3, exp_year: 2031 },
  });
  expect(screen.getByTestId('plan-card-on-file')).toHaveTextContent('Visa ending 4242');
  expect(screen.getByTestId('plan-card-on-file')).toHaveTextContent('Expires 03/31');
  expect(screen.getByRole('button', { name: 'Use a different card' })).toBeVisible();
});

test('someone who is not the owner is told who pays, and is offered no card form', () => {
  render(PlanStep, { billing: { ...billing, can_pay: false }, residentName: 'Aria' });
  expect(screen.getByTestId('plan-owner-only')).toHaveTextContent("The account's owner pays for new residents");
  expect(screen.queryByRole('button', { name: 'Add a card' })).not.toBeInTheDocument();
  expect(screen.queryByRole('radio')).not.toBeInTheDocument();
});

test('a failed payment says nothing was created', () => {
  render(PlanStep, { billing, residentName: 'Aria', payError: 'Your card was declined.' });
  expect(screen.getByTestId('plan-pay-error')).toHaveTextContent('Your card was declined. Nothing was created.');
});
