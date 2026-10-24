import { render, screen } from '@testing-library/svelte';
import ChatInputArea from './ChatInputArea.svelte';

// The chat page passes agentIsResponding whenever any resident is running.
// It used to disable the whole trigger bar, which made the queued-wake
// button (#252) unreachable from the real page while the standalone bar
// tests passed. A busy resident stays askable from the page itself.
test('a resident already responding can still be asked from the chat page', () => {
  render(ChatInputArea, {
    chat: { id: 'chat', manual_responses: true, respondable: true },
    agents: [
      { id: 'busy', name: 'Busy' },
      { id: 'idle', name: 'Idle' },
    ],
    accountId: 'account',
    agentIsResponding: true,
    activeRuntimeAgentIds: ['busy'],
  });
  expect(screen.getByRole('button', { name: 'Busy' })).toBeEnabled();
  expect(screen.getByRole('button', { name: 'Idle' })).toBeEnabled();
  expect(screen.getByRole('button', { name: 'Ask All' })).toBeEnabled();
});

test('an unrespondable conversation still disables the bar', () => {
  render(ChatInputArea, {
    chat: { id: 'chat', manual_responses: true, respondable: false },
    agents: [{ id: 'one', name: 'One' }],
    accountId: 'account',
  });
  expect(screen.getByRole('button', { name: 'One' })).toBeDisabled();
});
