import { render, screen, fireEvent } from '@testing-library/svelte';
import PlanStep from './plan-step.svelte';

const tiers = [
  {
    id: 'conversation',
    name: 'Small',
    size: 'small',
    monthly_usd: '9.99',
    allowance_usd: '10.00',
    purchasable: true,
    features: { hosting: true, allowance_usd: '10.00' },
  },
  {
    id: 'life',
    name: 'Medium',
    size: 'medium',
    monthly_usd: '19.99',
    allowance_usd: '10.00',
    purchasable: true,
    features: { hosting: true, allowance_usd: '10.00' },
  },
];
const accountPlans = [
  { id: 'companions', name: 'Companions', monthly_usd: '0.00', from_usd: '9.99', purchasable: false },
  { id: 'partners', name: 'Partners', monthly_usd: '20.00', from_usd: '29.99', purchasable: true },
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
  account_plans: accountPlans,
};

test('offers each size with its price, preselects small, and states the terms plainly', () => {
  render(PlanStep, { billing, residentName: 'Aria' });

  expect(screen.getByText('A computer for Aria')).toBeVisible();
  expect(screen.getByRole('radio', { name: 'Small' })).toBeChecked();
  expect(screen.getByRole('radio', { name: 'Medium' })).not.toBeChecked();
  expect(screen.getByText('Talking, thinking, writing, looking things up. Right for most residents.')).toBeVisible();
  expect(screen.queryByText(/vCPU|transcription|backups|WhatsApp/)).toBeNull();
  const terms = screen.getByTestId('plan-terms');
  expect(terms).toHaveTextContent("Today: $9.99 + VAT for Aria's first month.");
  expect(terms).toHaveTextContent('Then $9.99 + VAT each month until you cancel.');
  expect(terms).not.toHaveTextContent('Free for');
  expect(terms).toHaveTextContent('within 30 days for a full refund');
  expect(screen.getByTestId('plan-test-mode')).toHaveTextContent('4242 4242 4242 4242');
});

test('offers at cost beside standard when the account holds a code, and says what at cost means', () => {
  const offers = [
    { ...tiers[0], tier: 'conversation', rate: 'standard' },
    {
      id: 'conversation_at_cost',
      tier: 'conversation',
      size: 'small',
      rate: 'at_cost',
      name: 'Small at cost',
      monthly_usd: '8.00',
      purchasable: true,
      features: { hosting: true, allowance_usd: '0.00' },
    },
  ];
  render(PlanStep, { billing: { ...billing, offers }, residentName: 'Aria', tier: 'conversation_at_cost' });

  expect(screen.getByRole('radio', { name: /Small at cost/ })).toBeChecked();
  // One rate at a time: the switch shows At cost, and the standard card is not on screen.
  expect(screen.getByRole('button', { name: 'At cost' })).toHaveAttribute('aria-pressed', 'true');
  expect(screen.queryByRole('radio', { name: /^Small$/ })).toBeNull();
  expect(screen.getByTestId('plan-terms')).toHaveTextContent("Today: $8 + VAT for Aria's first month.");
  expect(screen.getByTestId('plan-at-cost-terms')).toHaveTextContent('includes no house-model allowance');
});

test('the rate switch moves to the same plan at the other rate', async () => {
  const offers = [
    { ...tiers[0], tier: 'conversation', rate: 'standard' },
    { ...tiers[1], tier: 'life', rate: 'standard' },
    {
      id: 'conversation_at_cost',
      tier: 'conversation',
      size: 'small',
      rate: 'at_cost',
      name: 'Small at cost',
      monthly_usd: '8.00',
      purchasable: true,
      features: { hosting: true, allowance_usd: '0.00' },
    },
    {
      id: 'life_at_cost',
      tier: 'life',
      size: 'medium',
      rate: 'at_cost',
      name: 'Medium at cost',
      monthly_usd: '11.00',
      purchasable: true,
      features: { hosting: true, allowance_usd: '0.00' },
    },
  ];
  render(PlanStep, { billing: { ...billing, offers }, residentName: 'Aria', tier: 'life' });
  expect(screen.getByRole('radio', { name: /^Medium$/ })).toBeChecked();
  await fireEvent.click(screen.getByRole('button', { name: 'At cost' }));
  expect(screen.getByRole('radio', { name: /Medium at cost/ })).toBeChecked();
  expect(screen.getByText('$3 a month more than small')).toBeInTheDocument();
  expect(screen.getByTestId('plan-terms')).toHaveTextContent("Today: $11 + VAT for Aria's first month.");
});

test('a draft the plan does not fit is told so', () => {
  render(PlanStep, {
    billing,
    residentName: 'Aria',
    blocked: 'At cost includes no house model, and Aria is set to think on the house.',
  });
  expect(screen.getByTestId('plan-blocked')).toHaveTextContent('At cost includes no house model');
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

test('medium and large sit behind a plain disclosure, priced against small', () => {
  render(PlanStep, { billing, residentName: 'Aria' });
  const bigger = screen.getByTestId('plan-bigger');
  expect(bigger).toHaveTextContent('Need a bigger computer?');
  expect(bigger.open).toBe(false);
  expect(bigger).toHaveTextContent('$10 a month more than small');
});

test('a medium resident already chosen opens the disclosure', () => {
  render(PlanStep, { billing, residentName: 'Aria', tier: 'life' });
  expect(screen.getByTestId('plan-bigger').open).toBe(true);
  expect(screen.getByTestId('plan-terms')).toHaveTextContent("Today: $19.99 + VAT for Aria's first month.");
});

test('names the account plan and links to Billing, without choosing it here', () => {
  render(PlanStep, {
    billing: { ...billing, account_plan: { id: 'partners', source: 'grant', subscription: null } },
    residentName: 'Aria',
    billingUrl: '/accounts/a/billing',
  });
  const line = screen.getByTestId('plan-account-plan');
  expect(line).toHaveTextContent('This account is on Partners.');
  expect(screen.getByRole('link', { name: 'Change it on the Billing tab' })).toHaveAttribute(
    'href',
    '/accounts/a/billing'
  );
  expect(screen.queryByRole('radio', { name: /Partners|Companions/ })).toBeNull();
});

test('without the account plan in the props it still links to Billing, naming no plan', () => {
  render(PlanStep, { billing, residentName: 'Aria', billingUrl: '/accounts/a/billing' });
  const line = screen.getByTestId('plan-account-plan');
  expect(line).not.toHaveTextContent('This account is on');
  expect(screen.getByRole('link', { name: 'Change it on the Billing tab' })).toBeVisible();
});

test('the free 14 days: a small resident asks for no card and says so', () => {
  render(PlanStep, { billing, residentName: 'Aria', trial: { eligible: true, days: 14 } });
  expect(screen.getByTestId('plan-trial')).toHaveTextContent('Free for 14 days. No card asked for.');
  expect(screen.getByTestId('plan-terms')).toHaveTextContent('With no card, Aria goes to sleep on day 14.');
  expect(screen.getByTestId('plan-terms')).not.toHaveTextContent('Today:');
  expect(screen.queryByRole('button', { name: 'Add a card' })).toBeNull();
});

test('the free 14 days are for small only: medium is paid from today', () => {
  render(PlanStep, { billing, residentName: 'Aria', tier: 'life', trial: { eligible: true, days: 14 } });
  expect(screen.queryByTestId('plan-trial')).toBeNull();
  expect(screen.getByTestId('plan-terms')).toHaveTextContent("Today: $19.99 + VAT for Aria's first month.");
  expect(screen.getByRole('button', { name: 'Add a card' })).toBeVisible();
});

test('an account that is not eligible, or props without a trial, behave as before', () => {
  for (const trial of [{ eligible: false, days: 14 }, null, undefined]) {
    const { unmount } = render(PlanStep, { billing, residentName: 'Aria', trial });
    expect(screen.queryByTestId('plan-trial')).toBeNull();
    expect(screen.getByRole('button', { name: 'Add a card' })).toBeVisible();
    unmount();
  }
});
