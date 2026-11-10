import { render, screen, within } from '@testing-library/svelte';
import { vi } from 'vitest';

vi.mock('@inertiajs/svelte', async () => {
  const { writable } = await import('svelte/store');
  return { page: writable({ props: { site_settings: { allow_signups: true } } }) };
});

const { default: Pricing } = await import('./pricing.svelte');
const { page } = await import('@inertiajs/svelte');

const signedOut = { site_settings: { allow_signups: true } };
afterEach(() => page.set({ props: signedOut }));

const tiers = [
  { id: 'conversation', name: 'Small', size: 'small', monthly_usd: '9.99', allowance_usd: '10.00', purchasable: true },
  { id: 'life', name: 'Medium', size: 'medium', monthly_usd: '19.99', allowance_usd: '10.00', purchasable: true },
  { id: 'work', name: 'Large', size: 'large', monthly_usd: '49.99', allowance_usd: '10.00', purchasable: true },
];
const accountPlans = [
  {
    id: 'companions',
    name: 'Companions',
    monthly_usd: '0.00',
    from_usd: '9.99',
    purchasable: false,
    features: { members: 'one', swarm_searches: 0, subagents: false },
  },
  {
    id: 'partners',
    name: 'Partners',
    monthly_usd: '20.00',
    from_usd: '29.99',
    purchasable: true,
    features: { members: 'several', swarm_searches: 20, subagents: false },
  },
  {
    id: 'colleagues',
    name: 'Colleagues',
    monthly_usd: '50.00',
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

test('residents by size, then model use, then the free 14 days with the paid plans never free', () => {
  render(Pricing, {
    tiers,
    account_plans: accountPlans,
    billing_open: true,
    contact_email: 'hello@example.com',
    free_trial_enabled: true,
  });
  const sizes = screen.getByTestId('pricing-sizes');
  expect(within(sizes).getByRole('rowheader', { name: 'Medium' })).toBeInTheDocument();
  expect(sizes).toHaveTextContent('$19.99');
  expect(sizes).toHaveTextContent('$10 more as the included one');
  expect(sizes).toHaveTextContent('$40 more as the included one');
  expect(screen.getByTestId('pricing-model-use')).toHaveTextContent(
    "Each account gets $10 a month of the house's own model"
  );
  const trial = screen.getByTestId('pricing-trial');
  expect(trial).toHaveTextContent('Free for 14 days, no card asked for');
  expect(screen.getByTestId('pricing-trial-paid-plans')).toHaveTextContent(
    "Partners and Colleagues are never free: their $20 or $50 a month is charged from the day you choose one, also while a resident's free 14 days are running, and needs a card."
  );
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
