import { render, screen, fireEvent } from '@testing-library/svelte';
import { vi } from 'vitest';

const post = vi.hoisted(() => vi.fn());
vi.mock('@inertiajs/svelte', () => ({ router: { post } }));

const { default: AccountPlanCard } = await import('./AccountPlanCard.svelte');

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
  {
    id: 'colleagues',
    name: 'Colleagues',
    monthly_usd: '50.00',
    from_usd: '59.99',
    purchasable: true,
    features: { members: 'several', swarm_searches: 100, subagents: true },
  },
];
const account = { id: 'acc' };

function show(accountPlan, canPay = true) {
  return render(AccountPlanCard, { account, accountPlan, accountPlans, canPay });
}

beforeEach(() => post.mockReset());

test('the default plan: Companions, with both paid plans offered and their charge stated before the click', async () => {
  show({ id: 'companions', source: 'default', subscription: null });
  const card = screen.getByTestId('account-plan');
  expect(card).toHaveTextContent('Account plan');
  expect(card).toHaveTextContent('Companions');
  expect(screen.getByTestId('account-plan-source')).toHaveTextContent('Every account starts on Companions.');
  expect(card).toHaveTextContent('One person in the account');
  expect(card).not.toHaveTextContent('$0');

  const terms = screen.getByTestId('account-plan-terms');
  expect(terms).toHaveTextContent('Partners is $20 a month + VAT; Colleagues is $50 a month + VAT');
  expect(terms).toHaveTextContent("charged from today, also while a resident's free 14 days are running");
  expect(terms).toHaveTextContent('needs a card');

  await fireEvent.click(screen.getByRole('button', { name: 'Move to Partners · $20 a month' }));
  expect(post).toHaveBeenCalledWith(
    '/accounts/acc/billing/account_plan_checkout',
    { plan: 'partners' },
    expect.any(Object)
  );
  expect(screen.getByRole('button', { name: 'Move to Colleagues · $50 a month' })).toBeVisible();
});

test('a subscription: says what it costs and when it renews, and moves by changing the price', async () => {
  show({
    id: 'partners',
    source: 'subscription',
    subscription: { status: 'active', current_period_end: '2026-12-10T00:00:00Z', cancel_at_period_end: false },
  });
  expect(screen.getByTestId('account-plan-source')).toHaveTextContent(
    'Partners is $20 a month + VAT, on top of the residents. Renews on 10 Dec 2026.'
  );
  expect(screen.getByTestId('account-plan')).toHaveTextContent('20 swarm searches a month');
  expect(screen.queryByRole('button', { name: /Move to Partners/ })).toBeNull();
  expect(screen.getByTestId('account-plan-terms')).toHaveTextContent('The new price starts today.');

  await fireEvent.click(screen.getByRole('button', { name: 'Move to Colleagues · $50 a month' }));
  expect(post).toHaveBeenCalledWith(
    '/accounts/acc/billing/account_plan_change',
    { plan: 'colleagues' },
    expect.any(Object)
  );
});

test('a subscription ending says the account goes back to Companions and nobody is removed', () => {
  show({
    id: 'colleagues',
    source: 'subscription',
    subscription: { status: 'active', current_period_end: '2026-12-10T00:00:00Z', cancel_at_period_end: true },
  });
  expect(screen.getByTestId('account-plan-source')).toHaveTextContent(
    'It ends on 10 Dec 2026, and the account goes back to Companions. Nobody is removed from it.'
  );
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
  expect(screen.queryByRole('button', { name: /Move to Partners/ })).toBeNull();
  expect(screen.getByRole('button', { name: 'Move to Colleagues · $50 a month' })).toBeVisible();
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
