import { cleanup, fireEvent, render, waitFor } from '@testing-library/svelte';
import { afterEach, expect, test, vi } from 'vitest';
import Integrations from './integrations.svelte';
import EditResident from '../agents/edit.svelte';
import ModelKeys from './agent_api_keys.svelte';
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
    expect(subscribeToModel).toHaveBeenCalledWith('IntegrationStatus', 'first', [
      'service_connections',
      'shared_connections',
    ])
  );
  expect(subscribeToModel.mock.calls.filter(([model]) => model === 'IntegrationStatus')).toHaveLength(1);
});

test('provider edit subscriptions preserve broad maps and reconcile rendered status without resubscribing', async () => {
  const props = {
    account: { id: 'first' },
    agent: { id: 'resident', name: 'Resident', runtime: 'external' },
    provider_subscription: {
      id: 'resident',
      name: 'Resident',
      provider: 'anthropic',
      provider_name: 'Claude',
      available: false,
      connection: { status: 'expired' },
    },
    active_tab: 'settings',
  };
  const view = render(EditResident, props);
  await waitFor(() =>
    expect(subscribeToModel).toHaveBeenCalledWith('ProviderPresentation', 'first', [
      'provider_subscription',
      'can_manage_provider_subscription',
    ])
  );
  expect(subscribeToModel).toHaveBeenCalledWith('Agent', 'resident', [
    'agent',
    'interactions',
    'interactions_pagination',
    'cost_report',
    'reflexes',
    'subagents_available',
    'plan_offer',
    'voice',
  ]);
  expect(subscribeToModel).toHaveBeenCalledWith('IntegrationStatus', 'first', [
    'service_connections',
    'shared_connections',
  ]);
  const providers = () => subscribeToModel.mock.calls.filter(([model]) => model === 'ProviderPresentation');
  const unsubscribe =
    subscribeToModel.mock.results[subscribeToModel.mock.calls.findIndex(([model]) => model === 'ProviderPresentation')]
      .value;
  await view.rerender({
    ...props,
    provider_subscription: {
      ...props.provider_subscription,
      connection: { status: 'connected', email: 'synthetic@example.test' },
    },
    can_manage_provider_subscription: true,
  });
  expect(view.getByText('Connected as synthetic@example.test')).toBeInTheDocument();
  expect(providers()).toHaveLength(1);
  await view.rerender({ ...props, account: { id: 'second' } });
  expect(providers()).toHaveLength(2);
  expect(providers()[1]).toEqual([
    'ProviderPresentation',
    'second',
    ['provider_subscription', 'can_manage_provider_subscription'],
  ]);
  expect(unsubscribe).toHaveBeenCalledOnce();
  view.unmount();
  expect(subscribeToModel.mock.results.at(-1).value).toHaveBeenCalledOnce();
});

test('model keys page does not subscribe to ProviderPresentation and preserves API key drafts', async () => {
  const props = {
    account: { id: 'first', name: 'First' },
    can_manage_ai_credentials: true,
    ai_api_keys_configured: { anthropic: true },
    residents: [{ id: 'resident', name: 'Resident' }],
  };
  const view = render(ModelKeys, props);
  expect(subscribeToModel).not.toHaveBeenCalled();
  const input = view.container.querySelector('#openai_api_key');
  await fireEvent.input(input, { target: { value: 'synthetic-unsaved-api-key' } });
  await fireEvent.click(view.getByRole('button', { name: 'Remove', exact: true }));
  expect(view.getByText('Will be removed')).toBeInTheDocument();
  await view.rerender({
    ...props,
    residents: [
      { id: 'resident', name: 'Resident' },
      { id: 'other', name: 'Other' },
    ],
  });
  expect(input).toHaveValue('synthetic-unsaved-api-key');
  expect(view.getByText('Will be removed')).toBeInTheDocument();
  expect(subscribeToModel).not.toHaveBeenCalled();
});
