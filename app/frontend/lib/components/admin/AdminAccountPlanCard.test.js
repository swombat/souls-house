import { render, screen, fireEvent } from '@testing-library/svelte';
import { expect, test, vi, beforeEach } from 'vitest';

const patch = vi.fn();
vi.mock('@inertiajs/svelte', () => ({ router: { patch: (...args) => patch(...args) } }));

import AdminAccountPlanCard from './AdminAccountPlanCard.svelte';

const plans = [
  { id: 'companions', name: 'Companions' },
  { id: 'partners', name: 'Partners' },
  { id: 'colleagues', name: 'Colleagues' },
];

function account(plan = {}) {
  return {
    id: 'acct',
    plan: {
      id: 'colleagues',
      name: 'Colleagues',
      source: 'grant',
      granted_plan: 'colleagues',
      plans,
      subscription: null,
      plan_codes: [],
      plan_to_pay_for: null,
      ...plan,
    },
  };
}

beforeEach(() => patch.mockReset());

test('says where the plan comes from and saves a new grant', async () => {
  render(AdminAccountPlanCard, {
    account: account({
      granted_plan: null,
      id: 'companions',
      name: 'Companions',
      source: 'default',
      plan_to_pay_for: 'companions',
    }),
  });

  expect(screen.getByTestId('plan-in-force')).toHaveTextContent('On Companions, the default');
  expect(screen.getByText(/A first bill would carry Companions/)).toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Save plan' })).toBeDisabled();

  await fireEvent.change(screen.getByLabelText('Plan from the house'), { target: { value: 'partners' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Save plan' }));

  expect(patch).toHaveBeenCalledWith('/admin/accounts/acct/granted_plan', { account: { granted_plan: 'partners' } });
});

test('a paid plan line stays on the bill', () => {
  render(AdminAccountPlanCard, {
    account: account({ subscription: { plan: 'partners', plan_name: 'Partners', status: 'active', in_force: true } }),
  });

  expect(screen.getByText(/pays for a Partners plan line \(active\)/)).toBeInTheDocument();
  expect(screen.getByText(/does not take that line off its bill/)).toBeInTheDocument();
});

test('a grant that covers the first bill says it carries no plan line', () => {
  render(AdminAccountPlanCard, { account: account() });
  expect(screen.getByText(/A first bill would carry no plan line/)).toBeInTheDocument();
});

test('lowering or removing the grant says nobody is removed', async () => {
  render(AdminAccountPlanCard, { account: account() });
  expect(screen.queryByRole('note')).toBeNull();

  await fireEvent.change(screen.getByLabelText('Plan from the house'), { target: { value: 'partners' } });
  expect(screen.getByRole('note')).toHaveTextContent('Nobody is removed from the account');
  expect(screen.getByRole('note')).toHaveTextContent('It loses what Colleagues gives beyond Partners');

  await fireEvent.change(screen.getByLabelText('Plan from the house'), { target: { value: '' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Save plan' }));
  expect(patch).toHaveBeenCalledWith('/admin/accounts/acct/granted_plan', { account: { granted_plan: '' } });
});

test('a live refresh of the same account keeps an unsaved choice', async () => {
  const { rerender } = render(AdminAccountPlanCard, { account: account() });
  await fireEvent.change(screen.getByLabelText('Plan from the house'), { target: { value: 'partners' } });

  await rerender({ account: { ...account(), users_count: 3 } });
  expect(screen.getByLabelText('Plan from the house')).toHaveValue('partners');
});
