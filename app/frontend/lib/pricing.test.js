import { describe, expect, it } from 'vitest';
import {
  accountPlanLines,
  accountPlanTaglines,
  planAction,
  sizeLines,
  sizeOf,
  trialAction,
  trialApplies,
  trialShown,
  usd,
} from './pricing';

const partners = {
  id: 'partners',
  name: 'Partners',
  monthly_usd: '20.00',
  from_usd: '29.99',
  purchasable: true,
  features: { members: 'several', swarm_searches: 20, subagents: false },
};
const companions = {
  id: 'companions',
  name: 'Companions',
  monthly_usd: '0.00',
  from_usd: '9.99',
  purchasable: true,
  features: { members: 'one', swarm_searches: 0, subagents: false },
};
const colleagues = {
  id: 'colleagues',
  name: 'Colleagues',
  monthly_usd: '50.00',
  from_usd: '59.99',
  purchasable: true,
  features: { members: 'several', swarm_searches: 100, subagents: true },
};
const unpriced = { ...partners, purchasable: false };
const account = { id: 'abc' };

describe('planAction', () => {
  it('offers no way to pay while a plan has no Stripe price', () => {
    for (const user of [null, { id: 1 }]) {
      expect(
        planAction({ plan: unpriced, billingOpen: true, user, account, isAccountAdmin: true, allowSignups: true })
      ).toEqual({ kind: 'soon', label: 'Opens soon' });
    }
  });

  it('offers no way to pay while billing is off for the house, even for a priced plan', () => {
    expect(
      planAction({ plan: partners, billingOpen: false, user: { id: 1 }, account, isAccountAdmin: true }).kind
    ).toBe('soon');
  });

  it('sends a signed-out visitor to signup, or to sign in when signups are closed', () => {
    expect(planAction({ plan: partners, billingOpen: true, allowSignups: true }).href).toBe('/signup');
    expect(planAction({ plan: partners, billingOpen: true, allowSignups: false }).href).toBe('/login');
  });

  it("sends an account manager to the account's Billing tab", () => {
    const action = planAction({ plan: partners, billingOpen: true, user: { id: 1 }, account, isAccountAdmin: true });
    expect(action).toEqual({ kind: 'link', label: 'Choose Partners in Billing', href: '/accounts/abc/billing' });
  });

  it('does not ask anyone to choose Companions: every account is on it to start with', () => {
    const action = planAction({ plan: companions, billingOpen: true, user: { id: 1 }, account, isAccountAdmin: true });
    expect(action.label).toBe('Go to Billing');
  });

  it('gives a member who cannot manage billing a note, not a link', () => {
    const action = planAction({ plan: partners, billingOpen: true, user: { id: 1 }, account, isAccountAdmin: false });
    expect(action.kind).toBe('note');
    expect(action.href).toBeUndefined();
  });
});

describe('accountPlanLines', () => {
  it('says what each plan includes, plainly', () => {
    expect(accountPlanLines(companions).map((line) => line.text)).toEqual(['One person in the account']);
    expect(accountPlanLines(partners).map((line) => line.text)).toEqual([
      'Several people in the account',
      '20 swarm searches a month',
    ]);
    expect(accountPlanLines(colleagues).map((line) => line.text)).toEqual([
      'Everything in Partners',
      'Residents can hand work to sub-agents',
      '100 swarm searches a month',
    ]);
  });
});

describe('copy', () => {
  it('has a tagline for each account plan and a line for each size', () => {
    expect(accountPlanTaglines).toEqual({
      companions: 'Someone to talk with.',
      partners: 'Helps you with your life.',
      colleagues: 'Does serious work beside you.',
    });
    expect(Object.keys(sizeLines)).toEqual(['small', 'medium', 'large']);
  });
});

describe('usd', () => {
  it('drops a whole amount to dollars and keeps cents otherwise', () => {
    expect(usd('9.99')).toBe('$9.99');
    expect(usd('20.00')).toBe('$20');
    expect(usd(10)).toBe('$10');
    expect(usd('10.5')).toBe('$10.50');
    expect(usd(19.99 - 9.99)).toBe('$10');
  });
});

describe('sizeOf and trialApplies', () => {
  const small = { id: 'conversation', tier: 'conversation', rate: 'standard' };
  it('reads the size, or works it out from the internal id for older props', () => {
    expect(sizeOf({ id: 'life', size: 'medium' })).toBe('medium');
    expect(sizeOf({ id: 'work' })).toBe('large');
    expect(sizeOf({ id: 'conversation_at_cost', tier: 'conversation' })).toBe('small');
  });

  it('applies the free days only to a small resident at the standard price, for an eligible account', () => {
    expect(trialApplies({ eligible: true, days: 14 }, small)).toBe(true);
    expect(trialApplies({ eligible: false, days: 14 }, small)).toBe(false);
    expect(trialApplies(null, small)).toBe(false);
    expect(trialApplies({ eligible: true }, { id: 'life', tier: 'life', rate: 'standard' })).toBe(false);
    expect(trialApplies({ eligible: true }, { ...small, id: 'conversation_at_cost', rate: 'at_cost' })).toBe(false);
  });
});

describe('trialShown and trialAction', () => {
  const offered = { billingOpen: true, freeTrialEnabled: true, smallPurchasable: true };

  it('shows the free 14 days only while the house offers them, and to a signed-in account only if eligible', () => {
    expect(trialShown({ ...offered, user: null, trial: null })).toBe(true);
    expect(trialShown({ ...offered, freeTrialEnabled: false, user: null })).toBe(false);
    expect(trialShown({ ...offered, billingOpen: false, user: null })).toBe(false);
    expect(trialShown({ ...offered, smallPurchasable: false, user: null })).toBe(false);
    expect(trialShown({ ...offered, user: { id: 1 }, trial: { eligible: true, days: 14 } })).toBe(true);
    expect(trialShown({ ...offered, user: { id: 1 }, trial: { eligible: false, days: 14 } })).toBe(false);
    expect(trialShown({ ...offered, user: { id: 1 }, trial: null })).toBe(false);
  });

  it('leads a visitor to sign up, an owner to the wizard, and tells a member who can start it', () => {
    expect(trialAction({ user: null, allowSignups: true })).toEqual({
      kind: 'link',
      label: 'Begin someone',
      href: '/signup',
    });
    expect(trialAction({ user: null, allowSignups: false })).toEqual({
      kind: 'link',
      label: 'Sign in',
      href: '/login',
    });
    expect(trialAction({ user: { id: 1 }, account: { id: 'home' }, isAccountAdmin: true })).toEqual({
      kind: 'link',
      label: 'Start free',
      href: '/accounts/home/agents/new',
    });
    expect(trialAction({ user: { id: 1 }, account: { id: 'home' }, isAccountAdmin: false }).kind).toBe('note');
  });
});
