import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { router } from '@inertiajs/svelte';
import Billing from './billing.svelte';

const tiers = [
  { id: 'life', name: 'Medium', size: 'medium', monthly_usd: '19.99', purchasable: true, features: {} },
  { id: 'work', name: 'Large', size: 'large', monthly_usd: '49.99', purchasable: true, features: {} },
];
const standard = { ...tiers[0], tier: 'life', rate: 'standard' };
const atCost = { ...standard, id: 'life_at_cost', name: 'Medium at cost', rate: 'at_cost', monthly_usd: '11.00' };
const work = { ...tiers[1], tier: 'work', rate: 'standard' };
const workAtCost = { ...work, id: 'work_at_cost', name: 'Large at cost', rate: 'at_cost', monthly_usd: '20.00' };
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
];
const codes = { eligible_rates: ['standard', 'at_cost'], redemptions: [{ effect: 'at_cost', code: 'HOST' }] };

function props(overrides = {}) {
  return {
    account: { id: 'home', name: 'Home' },
    billing: { configured: true, can_pay: true },
    tiers,
    offers: [standard, atCost],
    codes,
    residents: [{ id: 'resident', name: 'Resident', entitlement: { source: 'house', state: 'complimentary' } }],
    account_plans: accountPlans,
    account_plan: { id: 'companions', source: 'default', subscription: null },
    ...overrides,
  };
}

beforeEach(() => vi.clearAllMocks());
afterEach(cleanup);

describe('existing resident checkout', () => {
  it('offers eligible purchasable at-cost hosting and posts the resident, tier and rate', async () => {
    render(Billing, props());

    expect(screen.getByRole('button', { name: 'Medium · $19.99 a month' })).toBeInTheDocument();
    expect(screen.queryByText(/at cost is coming/i)).not.toBeInTheDocument();
    expect(screen.getByTestId('billing-at-cost')).toHaveTextContent('with no house-model allowance');
    expect(screen.getByTestId('billing-at-cost')).toHaveTextContent(
      'Connect and select your own model before checkout'
    );
    expect(screen.getByTestId('billing-at-cost')).toHaveTextContent("An existing resident's server is unchanged");
    await fireEvent.click(screen.getByRole('button', { name: 'Medium at cost · $11 a month' }));

    expect(router.post).toHaveBeenCalledWith(
      '/accounts/home/billing/checkout',
      { agent_id: 'resident', tier: 'life', rate: 'at_cost' },
      expect.objectContaining({ onFinish: expect.any(Function) })
    );
    expect(screen.getByRole('button', { name: 'Opening…' })).toBeDisabled();
  });

  it('does not invent at-cost offers for an ineligible account', () => {
    render(Billing, props({ offers: [standard], codes: { eligible_rates: ['standard'], redemptions: [] } }));

    expect(screen.getByRole('button', { name: 'Medium · $19.99 a month' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /at cost/i })).not.toBeInTheDocument();
    expect(screen.queryByTestId('billing-at-cost')).not.toBeInTheDocument();
  });

  it('does not offer an unavailable at-cost price even with an eligibility grant', () => {
    render(Billing, props({ offers: [standard, { ...atCost, purchasable: false }] }));

    expect(screen.queryByRole('button', { name: /at cost/i })).not.toBeInTheDocument();
    expect(screen.queryByTestId('billing-at-cost-price')).not.toBeInTheDocument();
  });

  it('respects an explicitly empty server offer list without falling back to tiers', () => {
    render(Billing, props({ offers: [] }));

    expect(screen.queryByRole('button', { name: /^(Small|Medium|Large).*· \$/ })).not.toBeInTheDocument();
  });

  it('retains standard-tier fallback only for older props without offers', () => {
    const legacy = props();
    delete legacy.offers;
    render(Billing, legacy);

    expect(screen.getByRole('button', { name: 'Medium · $19.99 a month' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /at cost/i })).not.toBeInTheDocument();
  });

  it.each([
    { configured: true, can_pay: false },
    { configured: false, can_pay: true },
  ])('does not expose checkout when billing is %j', (billing) => {
    render(Billing, props({ billing }));

    expect(screen.queryByRole('button', { name: /· \$/ })).not.toBeInTheDocument();
    expect(router.post).not.toHaveBeenCalled();
  });
});

describe('live subscriptions', () => {
  it.each(['standard', 'at_cost'])('keeps %s plan changes at the current rate, not checkout', async (rate) => {
    render(
      Billing,
      props({
        change_offers: [standard, atCost, work, workAtCost],
        residents: [
          {
            id: 'resident',
            name: 'Resident',
            entitlement: { source: 'stripe', state: 'active', tier: 'life', rate, subscription: { status: 'active' } },
          },
        ],
      })
    );

    const name = rate === 'at_cost' ? 'Move to Large at cost · $20 a month' : 'Move to Large · $49.99 a month';
    expect(screen.getAllByRole('button', { name: /^Move to (Small|Medium|Large).*· \$/ })).toHaveLength(1);
    await fireEvent.click(screen.getByRole('button', { name }));

    expect(router.post).toHaveBeenCalledWith(
      '/accounts/home/billing/plan_change',
      { agent_id: 'resident', tier: 'work' },
      expect.objectContaining({ onFinish: expect.any(Function) })
    );
  });

  it.each(['trialing', 'past_due', 'incomplete'])('does not start another checkout for %s subscriptions', (status) => {
    render(
      Billing,
      props({
        residents: [
          {
            id: 'resident',
            name: 'Resident',
            entitlement: { source: 'stripe', state: 'pending', tier: 'life', subscription: { status } },
          },
        ],
      })
    );

    expect(screen.queryByRole('button', { name: /^(Move to )?(Small|Medium|Large).*· \$/ })).not.toBeInTheDocument();
  });

  it('shows each paid resident its size and price', () => {
    render(
      Billing,
      props({
        residents: [
          {
            id: 'resident',
            name: 'Resident',
            entitlement: {
              source: 'stripe',
              state: 'active',
              tier: 'life',
              rate: 'standard',
              subscription: { status: 'active' },
            },
          },
        ],
      })
    );
    expect(screen.getByText('Medium', { selector: '[data-slot="badge"], span' })).toBeInTheDocument();
    expect(screen.getByTestId('resident-price')).toHaveTextContent('$19.99 a month');
  });
});

describe('account plan and the free 14 days', () => {
  it('shows the account plan card above the sizes', () => {
    render(Billing, props());
    expect(screen.getByTestId('account-plan')).toHaveTextContent('Companions');
    expect(screen.getByRole('button', { name: 'Move to Partners · $20 a month' })).toBeInTheDocument();
  });

  it('renders without account plan, trial or trial_ends_at props', () => {
    const legacy = props();
    delete legacy.account_plans;
    delete legacy.account_plan;
    render(Billing, legacy);
    expect(screen.queryByTestId('account-plan')).not.toBeInTheDocument();
    expect(screen.getByTestId('billing-plans')).toHaveTextContent('Residents, by size');
    expect(screen.queryByTestId('resident-trial')).not.toBeInTheDocument();
  });

  it('a resident in its free 14 days offers no size change and says when it sleeps', () => {
    render(
      Billing,
      props({
        billing: { configured: true, can_pay: true, has_customer: true },
        change_offers: [standard, work],
        residents: [
          {
            id: 'resident',
            name: 'Aria',
            trial_ends_at: '2026-11-24T00:00:00Z',
            entitlement: {
              source: 'stripe',
              state: 'active',
              tier: 'conversation',
              rate: 'standard',
              subscription: { status: 'trialing' },
            },
          },
        ],
      })
    );
    expect(screen.getByText('Free trial')).toBeInTheDocument();
    expect(screen.getByTestId('resident-trial')).toHaveTextContent('Free trial until 24 Nov 2026.');
    expect(screen.getByTestId('resident-trial')).toHaveTextContent(
      'Add a card from Manage billing to keep Aria awake after 24 Nov 2026'
    );
    expect(screen.getByTestId('account-plan-terms')).toHaveTextContent("also while a resident's free 14 days");
    expect(screen.queryByRole('button', { name: /^Move to (Medium|Large)/ })).not.toBeInTheDocument();
    expect(screen.getAllByRole('button', { name: 'Manage billing' }).length).toBeGreaterThan(0);
  });

  it('with no residents and the trial offered, the empty list mentions the free 14 days', () => {
    render(Billing, props({ residents: [], trial: { eligible: true, days: 14 } }));
    const empty = screen.getByTestId('billing-no-residents');
    expect(empty).toHaveTextContent(
      "This account doesn't host any residents yet. Its first can be small and free for 14 days, with no card asked for."
    );
    expect(screen.getByRole('link', { name: 'Create a resident' })).toHaveAttribute(
      'href',
      '/accounts/home/agents/new'
    );
  });

  it.each([[{ eligible: false, days: 14 }], [null]])(
    'an account without the trial (%o) is never told of one',
    (trial) => {
      const { container } = render(Billing, props({ residents: [], trial }));
      expect(screen.getByTestId('billing-no-residents')).toHaveTextContent(
        "This account doesn't host any residents yet."
      );
      expect(container).not.toHaveTextContent(/free for 14|free 14 days|free trial/i);
    }
  );
});
