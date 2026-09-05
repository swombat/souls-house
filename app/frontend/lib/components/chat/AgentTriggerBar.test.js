import { render, screen } from '@testing-library/svelte';
import AgentTriggerBar from './AgentTriggerBar.svelte';

test('keeps retired participants visible but unavailable alongside a paused offline harness', () => {
  render(AgentTriggerBar, {
    accountId: 'account',
    chatId: 'chat',
    agents: [
      { id: 'old', name: 'Old resident', deprecated: true, unavailability_reason: 'agent_deprecated' },
      { id: 'current', name: 'Current resident', runtime: 'offline', active: true, paused: true },
    ],
  });
  expect(screen.getByRole('button', { name: 'Old resident' })).toBeDisabled();
  expect(screen.getByRole('button', { name: 'Old resident' })).toHaveAttribute(
    'title',
    'Old resident · Deprecated · Unavailable'
  );
  expect(screen.getByRole('button', { name: 'Current resident' })).toBeEnabled();
  expect(screen.getByRole('button', { name: 'Ask All' })).toBeEnabled();
});

test('disables Ask All when no participant is available', () => {
  render(AgentTriggerBar, {
    accountId: 'account',
    chatId: 'chat',
    agents: [
      { id: 'old', name: 'Old resident', unavailability_reason: 'agent_deprecated' },
      { id: 'new', name: 'Starting resident', unavailability_reason: 'agent_provisioning' },
    ],
  });
  expect(screen.getByRole('button', { name: 'Ask All' })).toBeDisabled();
});
