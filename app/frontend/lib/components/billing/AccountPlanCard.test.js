import { render, screen, fireEvent } from '@testing-library/svelte';
import { vi } from 'vitest';

const post = vi.hoisted(() => vi.fn());
vi.mock('@inertiajs/svelte', () => ({ router: { post } }));

const { default: AccountPlanCard } = await import('./AccountPlanCard.svelte');

const accountPlans = [
  {
    id: 'companions',
    name: 'Companions',
    monthly_usd: '9.99',
    from_usd: '9.99',
    purchasable: true,
    features: { members: 'one', swarm_searches: 0, subagents: false },
  },
  {
    id: 'partners',
    name: 'Partners',
    monthly_usd: '29.99',
    from_usd: '29.99',
    purchasable: true,
    features: { members: 'several', swarm_searches: 20, subagents: false },
  },
  {
    id: 'colleagues',
    name: 'Colleagues',
    monthly_usd: '59.99',
    from_usd: '59.99',
    purchasable: true,
    features: { members: 'several', swarm_searches: 100, subagents: true },
  },
];
const account = { id: 'acc' };

function show(accountPlan, canPay = true, trialShown = true) {
  return render(AccountPlanCard, { account, accountPlan, accountPlans, canPay, trialShown });
}

beforeEach(() => post.mockReset());

test('no bill yet: the plan the first bill will carry, the others to choose, and nothing charged by choosing', async () => {
  show({ id: 'companions', source: 'default', subscription: null, chosen: 'companions' });
  const card = screen.getByTestId('account-plan');
  expect(card).toHaveTextContent('Account plan');
  expect(card).toHaveTextContent('Companions');
  expect(screen.getByTestId('account-plan-source')).toHaveTextContent(
    "Your first resident's bill will carry Companions: $9.99 a month + VAT, with that resident included. " +
      'Nothing is charged until then.'
  );
  expect(card).toHaveTextContent('One person in the account');
  expect(card).toHaveTextContent('One small resident included');
  expect(card).not.toHaveTextContent('$0');

  const terms = screen.getByTestId('account-plan-terms');
  expect(terms).toHaveTextContent('Partners is $29.99 a month + VAT; Colleagues is $59.99 a month + VAT, one small');
  expect(terms).toHaveTextContent('Choosing one charges nothing now: it starts with your first resident.');
  expect(terms).toHaveTextContent('Only Companions has the free days.');
  expect(screen.queryByRole('button', { name: /Companions/ })).toBeNull();

  await fireEvent.click(screen.getByRole('button', { name: 'Choose Partners · $29.99 a month' }));
  expect(post).toHaveBeenCalledWith(
    '/accounts/acc/billing/account_plan_checkout',
    { plan: 'partners' },
    expect.any(Object)
  );
  expect(screen.getByRole('button', { name: 'Choose Colleagues · $59.99 a month' })).toBeVisible();
});

test('a plan chosen for the first bill is the one shown, and Companions can be chosen back', () => {
  show({ id: 'companions', source: 'default', subscription: null, chosen: 'colleagues' });
  expect(screen.getByTestId('account-plan-source')).toHaveTextContent(
    "Your first resident's bill will carry Colleagues: $59.99 a month + VAT"
  );
  expect(screen.getByTestId('account-plan')).toHaveTextContent('100 swarm searches a month');
  expect(screen.getByRole('button', { name: 'Choose Companions · $9.99 a month' })).toBeVisible();
  expect(screen.queryByRole('button', { name: /Colleagues/ })).toBeNull();
});

test('a subscription: says what it costs and when it renews, and moves by changing the price', async () => {
  show({
    id: 'partners',
    source: 'subscription',
    subscription: { status: 'active', current_period_end: '2026-12-10T00:00:00Z', cancel_at_period_end: false },
  });
  expect(screen.getByTestId('account-plan-source')).toHaveTextContent(
    'Partners is $29.99 a month + VAT, one small resident included; any further resident is its size. Renews on 10 Dec 2026.'
  );
  expect(screen.getByTestId('account-plan')).toHaveTextContent('20 swarm searches a month');
  expect(screen.queryByRole('button', { name: /Move to Partners/ })).toBeNull();
  expect(screen.getByTestId('account-plan-terms')).toHaveTextContent('The new price starts today.');

  expect(screen.getByRole('button', { name: 'Move to Companions · $9.99 a month' })).toBeVisible();
  await fireEvent.click(screen.getByRole('button', { name: 'Move to Colleagues · $59.99 a month' }));
  expect(post).toHaveBeenCalledWith(
    '/accounts/acc/billing/account_plan_checkout',
    { plan: 'colleagues' },
    expect.any(Object)
  );
});

test('a subscription ending says the plan ends with the bill and nobody is removed', () => {
  show({
    id: 'colleagues',
    source: 'subscription',
    subscription: { status: 'active', current_period_end: '2026-12-10T00:00:00Z', cancel_at_period_end: true },
  });
  expect(screen.getByTestId('account-plan-source')).toHaveTextContent(
    'It ends with the bill on 10 Dec 2026. Nobody is removed from the account.'
  );
});

test('during the free days the plan says when they end and offers no move', () => {
  show({
    id: 'companions',
    source: 'subscription',
    subscription: { status: 'trialing', current_period_end: '2026-12-01T00:00:00Z', cancel_at_period_end: false },
  });
  expect(screen.getByTestId('account-plan-source')).toHaveTextContent(
    'Companions is free until 1 Dec 2026, its small resident with it. After that it is $9.99 a month + VAT.'
  );
  expect(screen.queryByTestId('account-plan-moves')).toBeNull();
});

test('a bill with no plan line offers every plan, added to the bill and quoted first', async () => {
  show({ id: 'companions', source: 'default', subscription: null, chosen: null, bill: true, includes_resident: true });
  expect(screen.getByTestId('account-plan-terms')).toHaveTextContent("It goes on the account's bill from today");
  expect(screen.getByTestId('account-plan-terms')).toHaveTextContent('You see what it costs before you confirm.');
  expect(screen.queryByTestId('account-plan-end')).toBeNull();
  await fireEvent.click(screen.getByRole('button', { name: 'Add Partners · $29.99 a month' }));
  expect(post).toHaveBeenCalledWith(
    '/accounts/acc/billing/account_plan_checkout',
    { plan: 'partners' },
    expect.any(Object)
  );
});

test('a paid plan is ended from the card, and an ending kept', async () => {
  show({
    id: 'partners',
    source: 'subscription',
    subscription: { status: 'active', current_period_end: '2026-12-10T00:00:00Z', cancel_at_period_end: false },
  });
  await fireEvent.click(screen.getByRole('button', { name: 'End Partners' }));
  expect(post).toHaveBeenCalledWith('/accounts/acc/billing/end_plan', {}, expect.any(Object));

  show({
    id: 'partners',
    source: 'subscription',
    subscription: { status: 'active', current_period_end: '2026-12-10T00:00:00Z', cancel_at_period_end: true },
  });
  expect(screen.getAllByTestId('account-plan').at(-1)).not.toHaveTextContent('Move to');
  await fireEvent.click(screen.getByRole('button', { name: 'Keep Partners' }));
  expect(post).toHaveBeenCalledWith('/accounts/acc/billing/keep_plan', {}, expect.any(Object));
});

test('during the free days there is no End or Keep on the plan: the trial resident carries it', () => {
  show({
    id: 'companions',
    source: 'subscription',
    subscription: { status: 'trialing', current_period_end: '2026-12-01T00:00:00Z', cancel_at_period_end: false },
  });
  expect(screen.queryByTestId('account-plan-end')).toBeNull();
});

test('a grant at the top on a bill offers no plan, and an account with an at-cost code is not told of an included resident', () => {
  show({ id: 'colleagues', source: 'grant', subscription: null, chosen: null, bill: true, includes_resident: false });
  expect(screen.queryByTestId('account-plan-moves')).toBeNull();
  expect(screen.getByTestId('account-plan')).not.toHaveTextContent('One small resident included');

  // Control: the same grant with no bill yet offers the higher plan, and the resident it includes.
  show({ id: 'partners', source: 'grant', subscription: null, chosen: null, bill: false, includes_resident: true });
  expect(screen.getAllByTestId('account-plan').at(-1)).toHaveTextContent('One small resident included');
  expect(screen.getByRole('button', { name: 'Choose Colleagues · $59.99 a month' })).toBeVisible();
});

test('a failed payment offers no move, only the way to fix it', () => {
  show({
    id: 'partners',
    source: 'subscription',
    subscription: { status: 'past_due', current_period_end: null, cancel_at_period_end: false },
  });
  expect(screen.getByTestId('account-plan-source')).toHaveTextContent('Update the card from Manage billing.');
  expect(screen.queryByTestId('account-plan-moves')).toBeNull();
});

test('a plan given by the house says so and offers nothing that would lower it', () => {
  show({ id: 'partners', source: 'grant', subscription: null });
  expect(screen.getByTestId('account-plan')).toHaveTextContent('Given by the house');
  expect(screen.getByTestId('account-plan-source')).toHaveTextContent(
    'The house gave this account Partners. There is nothing to pay for it.'
  );
  expect(screen.queryByRole('button', { name: /Partners/ })).toBeNull();
  expect(screen.queryByRole('button', { name: /Companions/ })).toBeNull();
  expect(screen.getByRole('button', { name: 'Choose Colleagues · $59.99 a month' })).toBeVisible();
});

test('Colleagues given by the house offers no purchase at all', () => {
  show({ id: 'colleagues', source: 'grant', subscription: null });
  expect(screen.getByTestId('account-plan')).toHaveTextContent('Everything in Partners');
  expect(screen.queryByTestId('account-plan-moves')).toBeNull();
  expect(screen.queryByRole('button')).toBeNull();
});

test('someone who is not the owner sees the plan but no buttons', () => {
  show({ id: 'companions', source: 'default', subscription: null }, false);
  expect(screen.getByTestId('account-plan')).toHaveTextContent('Companions');
  expect(screen.queryByRole('button')).toBeNull();
});

test('renders nothing when the props carry no account plan', () => {
  show(null);
  expect(screen.queryByTestId('account-plan')).toBeNull();
});

test('an account the tab offers no free trial is never told about one, and still sees the charge', () => {
  show({ id: 'companions', source: 'default', subscription: null, chosen: 'companions' }, true, false);
  const terms = screen.getByTestId('account-plan-terms');
  expect(terms).toHaveTextContent('Choosing one charges nothing now: it starts with your first resident.');
  expect(terms).not.toHaveTextContent(/free/i);
});
