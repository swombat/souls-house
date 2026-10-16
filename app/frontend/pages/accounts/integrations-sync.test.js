import { cleanup, render, waitFor } from '@testing-library/svelte';
import { afterEach, expect, test, vi } from 'vitest';
import Integrations from './integrations.svelte';
import EditResident from '../agents/edit.svelte';
import { subscribeToModel } from '$lib/cable';

vi.mock('$lib/cable', () => ({ subscribeToModel: vi.fn(() => vi.fn()) }));
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

test('empty integrations page subscribes narrowly and switches account without a reload loop', async () => {
  const view = render(Integrations, { account: { id: 'first', name: 'First' } });
  await waitFor(() =>
    expect(subscribeToModel).toHaveBeenCalledWith('IntegrationStatus', 'first', [
      'connections',
      'can_manage_account',
      'services',
    ])
  );
  const unsubscribe = subscribeToModel.mock.results[0].value;
  await view.rerender({ account: { id: 'first', name: 'Updated' }, connections: [] });
  expect(subscribeToModel).toHaveBeenCalledTimes(1);
  await view.rerender({ account: { id: 'second', name: 'Second' }, connections: [] });
  await waitFor(() => expect(subscribeToModel).toHaveBeenCalledTimes(2));
  expect(unsubscribe).toHaveBeenCalledOnce();
  expect(subscribeToModel).toHaveBeenLastCalledWith('IntegrationStatus', 'second', [
    'connections',
    'can_manage_account',
    'services',
  ]);
});

test('resident integration updates reload only safe service props, not settings or ceremony state', async () => {
  render(EditResident, {
    account: { id: 'first' },
    agent: { id: 'resident', name: 'Resident' },
    active_tab: 'integrations',
  });
  await waitFor(() =>
    expect(subscribeToModel).toHaveBeenCalledWith('IntegrationStatus', 'first', ['service_connections'])
  );
  expect(subscribeToModel.mock.calls.filter(([model]) => model === 'IntegrationStatus')).toHaveLength(1);
});
