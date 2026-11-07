import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { router } from '@inertiajs/svelte';
import Billing from './billing.svelte';

const tiers = [
  { id: 'life', name: 'Life', monthly_usd: 30, purchasable: true, features: {} },
  { id: 'work', name: 'Work', monthly_usd: 60, purchasable: true, features: {} },
];
const standard = { ...tiers[0], tier: 'life', rate: 'standard' };
const atCost = { ...standard, id: 'life_at_cost', name: 'Life at cost', rate: 'at_cost', monthly_usd: 10 };
const work = { ...tiers[1], tier: 'work', rate: 'standard' };
const workAtCost = { ...work, id: 'work_at_cost', name: 'Work at cost', rate: 'at_cost', monthly_usd: 20 };
const codes = { eligible_rates: ['standard', 'at_cost'], redemptions: [{ effect: 'at_cost', code: 'HOST' }] };

function props(overrides = {}) {
  return {
    account: { id: 'home', name: 'Home' },
    billing: { configured: true, can_pay: true },
    tiers,
    offers: [standard, atCost],
    codes,
    residents: [{ id: 'resident', name: 'Resident', entitlement: { source: 'house', state: 'complimentary' } }],
    ...overrides,
  };
}

beforeEach(() => vi.clearAllMocks());
afterEach(cleanup);

describe('existing resident checkout', () => {
  it('offers eligible purchasable at-cost hosting and posts the resident, tier and rate', async () => {
    render(Billing, props());

    expect(screen.getByRole('button', { name: 'Life · $30' })).toBeInTheDocument();
    expect(screen.queryByText(/at cost is coming/i)).not.toBeInTheDocument();
    expect(screen.getByTestId('billing-at-cost')).toHaveTextContent('with no house-model allowance');
    expect(screen.getByTestId('billing-at-cost')).toHaveTextContent(
      'Connect and select your own model before checkout'
    );
    expect(screen.getByTestId('billing-at-cost')).toHaveTextContent("An existing resident's VM size is unchanged");
    await fireEvent.click(screen.getByRole('button', { name: 'Life at cost · $10' }));

    expect(router.post).toHaveBeenCalledWith(
      '/accounts/home/billing/checkout',
      { agent_id: 'resident', tier: 'life', rate: 'at_cost' },
      expect.objectContaining({ onFinish: expect.any(Function) })
    );
    expect(screen.getByRole('button', { name: 'Opening…' })).toBeDisabled();
  });

  it('does not invent at-cost offers for an ineligible account', () => {
    render(Billing, props({ offers: [standard], codes: { eligible_rates: ['standard'], redemptions: [] } }));

    expect(screen.getByRole('button', { name: 'Life · $30' })).toBeInTheDocument();
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

    expect(screen.queryByRole('button', { name: /· \$/ })).not.toBeInTheDocument();
  });

  it('retains standard-tier fallback only for older props without offers', () => {
    const legacy = props();
    delete legacy.offers;
    render(Billing, legacy);

    expect(screen.getByRole('button', { name: 'Life · $30' })).toBeInTheDocument();
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

    const name = rate === 'at_cost' ? 'Move to Work at cost · $20' : 'Move to Work · $60';
    expect(screen.getAllByRole('button', { name: /· \$/ })).toHaveLength(1);
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

    expect(screen.queryByRole('button', { name: /· \$/ })).not.toBeInTheDocument();
  });
});
