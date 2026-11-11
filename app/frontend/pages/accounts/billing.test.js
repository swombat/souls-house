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

describe('adding a resident to the account subscription', () => {
  const pendingAdd = {
    attempt_id: 7,
    digest: 'abc',
    resident_name: 'Second',
    plan: 'Small',
    rate: 'standard',
    currency: 'usd',
    added_cents: 2200,
    next_total_cents: 6200,
    recurring_cents: 5500,
    next_at: '2026-12-01',
  };

  it("shows the server's quote and confirms exactly that quote", async () => {
    render(Billing, props({ pending_add: pendingAdd }));

    const panel = screen.getByTestId('billing-add-confirm');
    expect(panel).toHaveTextContent('Add Second on Small');
    expect(panel).toHaveTextContent('Your next bill, on 2026-12-01, goes up by about $22.00 for Second');
    expect(panel).toHaveTextContent('comes to about $62.00 in all');
    expect(panel).toHaveTextContent('about $55.00 a month for all its residents together');
    expect(panel).toHaveTextContent('Nothing is charged today.');

    await fireEvent.click(screen.getByRole('button', { name: 'Add Second' }));
    expect(router.post).toHaveBeenCalledWith(
      '/accounts/home/billing/add_resident',
      { attempt_id: 7, digest: 'abc' },
      expect.any(Object)
    );
  });

  it('shows no quote to someone who cannot pay', () => {
    render(Billing, props({ pending_add: pendingAdd, billing: { configured: true, can_pay: false } }));
    expect(screen.queryByTestId('billing-add-confirm')).not.toBeInTheDocument();
  });
});

describe('ending a resident plan', () => {
  const sub = (overrides = {}) => ({
    status: 'active',
    tier: 'life',
    current_period_end: '2026-12-01',
    cancel_at_period_end: false,
    ...overrides,
  });
  const resident = (subscription, name = 'Second') => ({
    id: name === 'Second' ? 'r2' : name.toLowerCase(),
    name,
    entitlement: { source: 'stripe', state: 'active', tier: 'life', subscription },
  });

  it('offers End only for a live paid plan, and posts the resident', async () => {
    render(
      Billing,
      props({ residents: [resident(sub()), resident(sub({ status: 'canceled' }), 'Gone'), resident(null, 'Free')] })
    );
    expect(screen.getAllByRole('button', { name: /^End .*'s plan$/ })).toHaveLength(1);
    await fireEvent.click(screen.getByRole('button', { name: "End Second's plan" }));
    expect(router.post).toHaveBeenCalledWith('/accounts/home/billing/end_plan', { agent_id: 'r2' }, expect.any(Object));
  });

  it('offers End for a trialing plan', () => {
    render(Billing, props({ residents: [resident(sub({ status: 'trialing' }))] }));
    expect(screen.getByRole('button', { name: "End Second's plan" })).toBeInTheDocument();
  });

  it('hides End and Keep from someone who cannot pay', () => {
    const billing = { configured: true, can_pay: false };
    render(
      Billing,
      props({ billing, residents: [resident(sub()), resident(sub({ cancel_at_period_end: true }), 'Other')] })
    );
    expect(screen.queryByTestId('end-plan-controls')).not.toBeInTheDocument();
  });

  it('shows the end date and Keep only when the plan is set to end, and posts the resident', async () => {
    render(Billing, props({ residents: [resident(sub({ cancel_at_period_end: true }))] }));
    expect(screen.getByText("Ends on 1 Dec 2026; won't renew.")).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: "End Second's plan" })).not.toBeInTheDocument();
    await fireEvent.click(screen.getByRole('button', { name: "Keep Second's plan" }));
    expect(router.post).toHaveBeenCalledWith(
      '/accounts/home/billing/keep_plan',
      { agent_id: 'r2' },
      expect.any(Object)
    );
  });

  it('shows no Keep button for a plan that is not ending', () => {
    render(Billing, props({ residents: [resident(sub())] }));
    expect(screen.queryByRole('button', { name: /Keep/ })).not.toBeInTheDocument();
  });

  it('shows the confirmation panel for a pending end, only to someone who can pay', () => {
    const pending_end = {
      attempt_id: 3,
      digest: 'd',
      resident_name: 'Second',
      operation: 'period_end',
      ends_at: '2026-12-01',
      final_total_cents: 0,
    };
    const { unmount } = render(Billing, props({ pending_end }));
    expect(screen.getByTestId('billing-end-confirm')).toBeInTheDocument();
    unmount();
    render(Billing, props({ pending_end, billing: { configured: true, can_pay: false } }));
    expect(screen.queryByTestId('billing-end-confirm')).not.toBeInTheDocument();
  });
});
