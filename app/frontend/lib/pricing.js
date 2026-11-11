// What people pay for, in words. Copy, not catalogue: the prices and what each
// plan includes come from the server (Billing::AccountPlan, Billing::Tier).
// Shared by /pricing, the Billing tab and the creation wizard; the about-sheet
// (app/models/about_sheet.rb) reads the two maps below from this file.
//
// An account is on a plan (Companions, Partners or Colleagues; Daniel named
// them, 2026-11-10), and each resident is paid for by the size of the
// computer it lives on. The internal size ids stay conversation/life/work.

// One line under each account plan's name: the kind of relationship it is for.
export const accountPlanTaglines = {
  companions: 'Someone to talk with.',
  partners: 'Helps you with your life.',
  colleagues: 'Does serious work beside you.',
};

// One line for each resident size: what it is right for.
export const sizeLines = {
  small: 'Talking, thinking, writing, looking things up. Right for most residents.',
  medium: 'Residents that write code or drive a browser.',
  large: 'Heavy building, and several sub-agents at once.',
};

const SIZE_BY_TIER = { conversation: 'small', life: 'medium', work: 'large' };

// The size of a tier or offer ("small", "medium", "large"). Older props carry
// no size, only the internal id.
export function sizeOf(option) {
  if (!option) return null;
  return option.size ?? SIZE_BY_TIER[option.tier ?? option.id] ?? null;
}

// Money for people: "$9.99", "$20". The server sends two-place strings.
export function usd(amount) {
  const value = Number(amount);
  if (!Number.isFinite(value)) return '';
  // In cents, so a difference such as 19.99 - 9.99 reads as $10.
  const cents = Math.round(value * 100);
  return cents % 100 === 0 ? `$${cents / 100}` : `$${(cents / 100).toFixed(2)}`;
}

// What an account plan includes, as short lines (Billing::AccountPlan#features).
export function accountPlanLines(plan) {
  const features = plan?.features ?? {};
  const lines = [];
  if (features.subagents) {
    lines.push({ key: 'everything', text: 'Everything in Partners' });
    lines.push({ key: 'subagents', text: 'Residents can hand work to sub-agents' });
  } else {
    lines.push({
      key: 'members',
      text: features.members === 'several' ? 'Several people in the account' : 'One person in the account',
    });
  }
  if (features.swarm_searches > 0) {
    lines.push({ key: 'swarm', text: `${features.swarm_searches} swarm searches a month` });
  }
  return lines;
}

// What a plan card on /pricing offers. A house with billing off, or a plan
// that can't be bought yet, offers no way to pay: the card says it opens soon.
export function planAction({ plan, billingOpen, user, account, isAccountAdmin, allowSignups }) {
  if (!billingOpen || !plan?.purchasable) return { kind: 'soon', label: 'Opens soon' };

  if (user) {
    if (account && isAccountAdmin) {
      const label = Number(plan.monthly_usd) > 0 ? `Choose ${plan.name} in Billing` : 'Go to Billing';
      return { kind: 'link', label, href: `/accounts/${account.id}/billing` };
    }
    return { kind: 'note', label: "The account's owner chooses its plan, on the Billing tab." };
  }

  if (allowSignups) return { kind: 'link', label: 'Begin someone', href: '/signup' };
  return { kind: 'link', label: 'Sign in', href: '/login' };
}

// The free 14 days' action on /pricing. Signed out, the same as a plan's:
// signing up lands a new account in the creation wizard. Signed in, the
// account's owner (or admin) goes straight to the wizard.
export function trialAction({ user, account, isAccountAdmin, allowSignups }) {
  if (!user) return planAction({ plan: { purchasable: true }, billingOpen: true, user, allowSignups });
  if (account && isAccountAdmin)
    return { kind: 'link', label: 'Start free', href: `/accounts/${account.id}/agents/new` };
  return { kind: 'note', label: "The account's owner can start it when creating its first resident." };
}

// Whether /pricing mentions the free 14 days: the house offers them (Site
// Admin's switch, and a small resident can be bought), and a signed-in
// visitor's account would get them (trial.eligible). An account that has had
// its trial, or can't have one, is never told it's free.
export function trialShown({ billingOpen, freeTrialEnabled, smallPurchasable, user, trial }) {
  if (!billingOpen || !freeTrialEnabled || !smallPurchasable) return false;
  return user ? Boolean(trial?.eligible) : true;
}

// Whether the wizard's free 14 days apply to the chosen size: the account is
// eligible (the server decides: its first resident, once per account) and
// the resident is small, at the standard price.
export function trialApplies(trial, option) {
  return Boolean(trial?.eligible) && sizeOf(option) === 'small' && (option?.rate ?? 'standard') === 'standard';
}
