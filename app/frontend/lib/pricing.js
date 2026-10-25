// One line under each plan's name. Copy, not catalogue: it says what kind of
// relationship the plan is for, never what it includes (that comes from the
// catalogue). Daniel named the plans this way, WjNvXj 2026-10-14. Shared by
// /pricing and the creation wizard's Plan step.
export const planTaglines = {
  conversation: 'Someone to talk with.',
  life: 'Helps you with your life.',
  work: 'Does serious work beside you.',
};

// What a plan card on /pricing offers. A plan with no Stripe price, or a house
// with billing off, offers no way to pay: the card says plans open soon.
export function planAction({ tier, billingOpen, user, account, isAccountAdmin, allowSignups }) {
  if (!billingOpen || !tier?.purchasable) return { kind: 'soon', label: 'Opens soon' };

  if (user) {
    if (account && isAccountAdmin) {
      return { kind: 'link', label: `Choose ${tier.name} in Billing`, href: `/accounts/${account.id}/billing` };
    }
    return { kind: 'note', label: "Plans are chosen from the account's Billing tab by its owner." };
  }

  if (allowSignups) return { kind: 'link', label: 'Begin someone', href: '/signup' };
  return { kind: 'link', label: 'Sign in', href: '/login' };
}
