import { describe, expect, it } from 'vitest';
import { planAction } from './pricing';

const priced = { id: 'starter', name: 'Starter', purchasable: true };
const unpriced = { id: 'starter', name: 'Starter', purchasable: false };
const account = { id: 'abc' };

describe('planAction', () => {
  it('offers no way to pay while a plan has no Stripe price', () => {
    for (const user of [null, { id: 1 }]) {
      expect(
        planAction({ tier: unpriced, billingOpen: true, user, account, isAccountAdmin: true, allowSignups: true })
      ).toEqual({ kind: 'soon', label: 'Opens soon' });
    }
  });

  it('offers no way to pay while billing is off for the house, even for a priced plan', () => {
    expect(planAction({ tier: priced, billingOpen: false, user: { id: 1 }, account, isAccountAdmin: true }).kind).toBe(
      'soon'
    );
  });

  it('sends a signed-out visitor to signup, or to sign in when signups are closed', () => {
    expect(planAction({ tier: priced, billingOpen: true, allowSignups: true }).href).toBe('/signup');
    expect(planAction({ tier: priced, billingOpen: true, allowSignups: false }).href).toBe('/login');
  });

  it("sends an account manager to the account's Billing tab", () => {
    expect(planAction({ tier: priced, billingOpen: true, user: { id: 1 }, account, isAccountAdmin: true }).href).toBe(
      '/accounts/abc/billing'
    );
  });

  it('gives a member who cannot manage billing a note, not a link', () => {
    const action = planAction({ tier: priced, billingOpen: true, user: { id: 1 }, account, isAccountAdmin: false });
    expect(action.kind).toBe('note');
    expect(action.href).toBeUndefined();
  });
});
