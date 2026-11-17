// The numbers the house's copy states, from the server constants that
// enforce them (Billing.public_numbers, shared with every page as
// billing_numbers). No page keeps a copy of its own: a copy is what said
// $20 / $50 / $100 for weeks after the prices changed.
//
// There is one house-model allowance, the account's (Billing::Allowance): a
// month of it, or the whole free trial. No resident or person has one.
import { usd } from '$lib/pricing';

export function billingNumbers(props) {
  const numbers = props?.billing_numbers ?? {};
  return {
    accountAllowance: usd(numbers.account_allowance_usd),
    trialDays: numbers.trial_days,
    graceDays: numbers.grace_days,
  };
}
