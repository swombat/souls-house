// The numbers the house's copy states, from the server constants that
// enforce them (Billing.public_numbers, shared with every page as
// billing_numbers). No page keeps a copy of its own: a copy is what said
// $20 / $50 / $100 for weeks after the prices changed.
//
// The four allowances are different things that are $10 each today: the
// account's month, the free trial's whole run, a free-hosted resident's own
// month, and a user's one on-the-house resident. Keep them apart.
import { usd } from '$lib/pricing';

export function billingNumbers(props) {
  const numbers = props?.billing_numbers ?? {};
  return {
    accountAllowance: usd(numbers.account_allowance_usd),
    trialAllowance: usd(numbers.trial_allowance_usd),
    freeHostingAllowance: usd(numbers.free_hosting_allowance_usd),
    onTheHouseAllowance: usd(numbers.on_the_house_allowance_usd),
    trialDays: numbers.trial_days,
    graceDays: numbers.grace_days,
  };
}
