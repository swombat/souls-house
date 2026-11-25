import { render, screen, within } from '@testing-library/svelte';
import { vi } from 'vitest';

vi.mock('@inertiajs/svelte', async () => {
  const { writable } = await import('svelte/store');
  const { BILLING_NUMBERS } = await import('../test/billing-numbers-fixture.js');
  return { page: writable({ props: { site_settings: { allow_signups: true }, billing_numbers: BILLING_NUMBERS } }) };
});

const { default: Pricing } = await import('./pricing.svelte');
const { page } = await import('@inertiajs/svelte');

const { BILLING_NUMBERS } = await import('../test/billing-numbers-fixture.js');
const signedOut = { site_settings: { allow_signups: true }, billing_numbers: BILLING_NUMBERS };
afterEach(() => page.set({ props: signedOut }));

const tiers = [
  { id: 'conversation', name: 'Small', size: 'small', monthly_usd: '9.99', allowance_usd: '10.00', purchasable: true },
  { id: 'life', name: 'Medium', size: 'medium', monthly_usd: '39.99', allowance_usd: '10.00', purchasable: true },
  { id: 'work', name: 'Large', size: 'large', monthly_usd: '69.99', allowance_usd: '10.00', purchasable: true },
];
const accountPlans = [
  {
    id: 'companions',
    name: 'Companions',
    monthly_usd: '9.99',
    from_usd: '9.99',
    purchasable: true,
    features: { members: 'one', swarm_searches: 0, subagents: false },
  },
  {
    id: 'partners',
    name: 'Partners',
    monthly_usd: '29.99',
    from_usd: '29.99',
    purchasable: true,
    features: { members: 'several', swarm_searches: 20, subagents: false },
  },
  {
    id: 'colleagues',
    name: 'Colleagues',
    monthly_usd: '59.99',
    from_usd: '59.99',
    purchasable: true,
    features: { members: 'several', swarm_searches: 100, subagents: true },
  },
];

function card(id) {
  return document.querySelector(`[data-plan="${id}"]`);
}

test('three account plan cards lead with what an account pays, one small resident included, never $0', () => {
  render(Pricing, { tiers, account_plans: accountPlans, billing_open: true, contact_email: 'hello@example.com' });
  expect(card('companions')).toHaveTextContent('Companions');
  expect(card('companions')).toHaveTextContent('Someone to talk with.');
  expect(card('companions').querySelector('[data-plan-price]')).toHaveTextContent('$9.99');
  expect(card('partners').querySelector('[data-plan-price]')).toHaveTextContent('$29.99');
  expect(card('colleagues').querySelector('[data-plan-price]')).toHaveTextContent('$59.99');
  for (const id of ['companions', 'partners', 'colleagues']) {
    expect(card(id)).toHaveTextContent('including one small resident');
    expect(card(id)).not.toHaveTextContent('$0');
    expect(card(id)).not.toHaveTextContent(/free/i);
  }
  expect(card('colleagues')).toHaveTextContent('Residents can hand work to sub-agents');
  // Companions has no Stripe price of its own; it can still be begun.
  expect(within(card('companions')).getByRole('link', { name: 'Begin someone' })).toBeInTheDocument();
});

test('residents by size, then model use, then the free 14 days, which the paid plans are not part of', () => {
  render(Pricing, {
    tiers,
    account_plans: accountPlans,
    billing_open: true,
    contact_email: 'hello@example.com',
    free_trial_enabled: true,
  });
  const sizes = screen.getByTestId('pricing-sizes');
  expect(within(sizes).getByRole('heading', { name: 'Medium' })).toBeInTheDocument();
  expect(sizes).toHaveTextContent('$39.99');
  expect(sizes).toHaveTextContent('+$30 a month as your included resident');
  expect(screen.getByTestId('pricing-model-use')).toHaveTextContent(
    "Each account gets $10 a month of the house's own model"
  );
  expect(screen.getByTestId('pricing-model-use')).toHaveTextContent(
    "It is shared by the account's residents at the standard price, not given to each resident, and residents hosted at cost don't draw on it."
  );
  expect(screen.getByTestId('pricing-model-use')).not.toHaveTextContent('first resident');
  const trial = screen.getByTestId('pricing-trial');
  expect(trial).toHaveTextContent('Free for 14 days, no card asked for: Companions and the small resident it includes');
  expect(screen.getByTestId('pricing-trial-paid-plans')).toHaveTextContent(
    "Partners and Colleagues are not part of them: their $29.99 or $59.99 a month needs a card. An account that chooses one pays from its first resident, and one can't be added while the free days run."
  );
  expect(document.body).not.toHaveTextContent(/never free/i);
});

test('the numbers it states are the server constants, not copies (negative control)', () => {
  page.set({
    props: {
      ...signedOut,
      billing_numbers: { ...BILLING_NUMBERS, account_allowance_usd: '12.50', trial_days: 21, grace_days: 9 },
    },
  });
  const plans = accountPlans.map((plan) =>
    plan.id === 'partners' ? { ...plan, features: { ...plan.features, swarm_searches: 33 } } : plan
  );
  render(Pricing, {
    tiers,
    account_plans: plans,
    billing_open: true,
    contact_email: 'hello@example.com',
    free_trial_enabled: true,
  });
  expect(screen.getByTestId('pricing-model-use')).toHaveTextContent(
    "Each account gets $12.50 a month of the house's own model"
  );
  expect(screen.getByTestId('pricing-trial')).toHaveTextContent('Free for 21 days');
  expect(screen.getByTestId('pricing-trial')).toHaveTextContent('goes to sleep on day 21');
  expect(document.body).toHaveTextContent('Partners includes 33 and Colleagues includes 100 swarm searches a month');
  expect(document.body).toHaveTextContent('there are 9 days to fix the card first');
  expect(document.body).not.toHaveTextContent(/\$10 a month|14 days|includes 20/);
});

test('how to cancel says what End plan does, not a portal that cannot cancel', () => {
  render(Pricing, {
    tiers,
    account_plans: accountPlans,
    billing_open: true,
    contact_email: 'hello@example.com',
    free_trial_enabled: false,
  });
  expect(document.body).toHaveTextContent('with End plan on the resident');
  expect(document.body).toHaveTextContent('the unused part of the month is credit on the next bill');
  expect(document.body).toHaveTextContent(
    'The plan stays when its last resident leaves: end it with End plan on the account plan, and a smaller plan is a move on the Billing tab'
  );
  expect(document.body).not.toHaveTextContent('To end a Partners or Colleagues plan');
  expect(document.body).not.toHaveTextContent(/Stripe's billing page|Stripe's portal/);
});

test('with the trial switched off there is no free line at all', () => {
  render(Pricing, {
    tiers,
    account_plans: accountPlans,
    billing_open: true,
    contact_email: 'hello@example.com',
    free_trial_enabled: false,
  });
  expect(screen.queryByTestId('pricing-trial')).toBeNull();
});

test('with billing off, every card says it opens soon', () => {
  render(Pricing, { tiers, account_plans: accountPlans, billing_open: false, contact_email: 'hello@example.com' });
  for (const id of ['companions', 'partners', 'colleagues']) expect(card(id)).toHaveTextContent('Opens soon');
});

test('with billing off there is no free line either', () => {
  render(Pricing, { tiers, account_plans: accountPlans, billing_open: false, contact_email: 'hello@example.com' });
  expect(screen.queryByTestId('pricing-trial')).toBeNull();
});

describe('the free 14 days and where they lead', () => {
  const open = {
    tiers,
    account_plans: accountPlans,
    billing_open: true,
    contact_email: 'hello@example.com',
    free_trial_enabled: true,
  };
  const owner = {
    ...signedOut,
    user: { id: 1 },
    account: { id: 'home' },
    is_account_admin: true,
  };

  test('signed out: the action signs up, which lands a new account in the wizard', () => {
    render(Pricing, open);
    expect(within(screen.getByTestId('pricing-trial')).getByRole('link', { name: 'Begin someone' })).toHaveAttribute(
      'href',
      '/signup'
    );
  });

  test("signed in as the owner of an eligible account: Start free opens the account's wizard", () => {
    page.set({ props: owner });
    render(Pricing, { ...open, trial: { eligible: true, days: 14 } });
    expect(within(screen.getByTestId('pricing-trial')).getByRole('link', { name: 'Start free' })).toHaveAttribute(
      'href',
      '/accounts/home/agents/new'
    );
  });

  test.each([
    ['has had its trial', { eligible: false, days: 14 }],
    ['sent no trial', null],
  ])('signed in, an account that %s never sees "free" next to a price', (_, trial) => {
    page.set({ props: owner });
    const { container } = render(Pricing, { ...open, trial });
    expect(screen.queryByTestId('pricing-trial')).toBeNull();
    expect(container.querySelector('[data-plan="companions"]').parentElement).not.toHaveTextContent(
      /free for|free 14/i
    );
    expect(screen.getByTestId('pricing-sizes')).not.toHaveTextContent(/free/i);
  });

  test('no switch in the props reads as off', () => {
    const { free_trial_enabled: _, ...withoutSwitch } = open;
    render(Pricing, withoutSwitch);
    expect(screen.queryByTestId('pricing-trial')).toBeNull();
  });
});

describe('residents by size, as cards', () => {
  const machines = {
    conversation: { vcpus: 2, ram_gb: 4 },
    life: { vcpus: 4, ram_gb: 8 },
    work: { vcpus: 8, ram_gb: 16 },
  };
  const withMachines = tiers.map((tier) => ({ ...tier, machine: machines[tier.id] }));
  const sizeCard = (size) => document.querySelector(`[data-testid="pricing-sizes"] [data-size="${size}"]`);

  test('one card per size: name, price, what it costs as the included resident, what it is for', () => {
    render(Pricing, { tiers: withMachines, account_plans: accountPlans, billing_open: true });
    expect(screen.getByTestId('pricing-sizes').querySelector('table')).toBeNull();
    expect(sizeCard('small').querySelector('[data-size-price]')).toHaveTextContent('$9.99');
    expect(sizeCard('small').querySelector('[data-size-included]')).toHaveTextContent('Included in every plan');
    expect(sizeCard('small').querySelector('[data-size-badge]')).toHaveTextContent('What most residents need');
    expect(sizeCard('medium').querySelector('[data-size-badge]')).toBeNull();
    expect(sizeCard('medium').querySelector('[data-size-price]')).toHaveTextContent('$39.99');
    expect(sizeCard('medium').querySelector('[data-size-included]')).toHaveTextContent(
      '+$30 a month as your included resident'
    );
    expect(sizeCard('large').querySelector('[data-size-included]')).toHaveTextContent(
      '+$60 a month as your included resident'
    );
    expect(sizeCard('small').querySelectorAll('[data-size-uses] li')).toHaveLength(3);
    expect(sizeCard('medium')).toHaveTextContent('Writing code');
    expect(sizeCard('large')).toHaveTextContent('Several sub-agents at once');
  });

  test('the differences come from the prices the server sends, never typed', () => {
    const repriced = withMachines.map((tier) => ({
      ...tier,
      monthly_usd: { conversation: '12.00', life: '15.50', work: '30.00' }[tier.id],
    }));
    render(Pricing, { tiers: repriced, account_plans: accountPlans, billing_open: true });
    expect(sizeCard('medium').querySelector('[data-size-included]')).toHaveTextContent('+$3.50 a month');
    expect(sizeCard('large').querySelector('[data-size-included]')).toHaveTextContent('+$18 a month');
  });

  test('the computer is named only when the server says each resident gets one', () => {
    render(Pricing, { tiers: withMachines, account_plans: accountPlans, billing_open: true });
    expect(sizeCard('small').querySelector('[data-size-machine]')).toHaveTextContent(
      'Its own computer: 2 cores, 4 GB memory'
    );
    expect(sizeCard('large').querySelector('[data-size-machine]')).toHaveTextContent('8 cores, 16 GB memory');
    expect(screen.getByTestId('pricing-sizes')).toHaveTextContent('Each resident lives on a computer of its own.');
  });

  test('no machine in the props: no computer claimed, not even in the intro', () => {
    render(Pricing, { tiers, account_plans: accountPlans, billing_open: true });
    expect(document.querySelector('[data-size-machine]')).toBeNull();
    expect(screen.getByTestId('pricing-sizes')).not.toHaveTextContent(/computer/i);
  });

  test('billing open and a size not purchasable: that card says it opens soon, with no price', () => {
    const closed = withMachines.map((tier) => (tier.id === 'work' ? { ...tier, purchasable: false } : tier));
    render(Pricing, { tiers: closed, account_plans: accountPlans, billing_open: true });
    expect(sizeCard('large').querySelector('[data-size-price]')).toHaveTextContent('Opens soon');
    expect(sizeCard('large')).not.toHaveTextContent('$69.99');
    expect(sizeCard('medium').querySelector('[data-size-price]')).toHaveTextContent('$39.99');
  });
});
