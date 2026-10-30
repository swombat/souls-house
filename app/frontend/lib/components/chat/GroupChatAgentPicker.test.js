import { render, screen, fireEvent } from '@testing-library/svelte';
import { vi } from 'vitest';

vi.mock('$lib/agent-subscription-usage', async (importOriginal) => ({
  ...(await importOriginal()),
  sortAgentsByAvailability: (agents) => agents,
  watchAgentsRemaining: () => () => {},
}));

import GroupChatAgentPicker from './GroupChatAgentPicker.svelte';

const agents = [
  { id: 'm', name: 'Mira', colour: 'violet' },
  { id: 'l', name: 'Lume', colour: 'orange' },
  { id: 'c', name: 'Chris', colour: 'stone' },
];

test('shows one line for all residents until Change is pressed', async () => {
  render(GroupChatAgentPicker, { agents, accountId: 'a', selectedAgentIds: ['m', 'l', 'c'] });
  expect(screen.getByTestId('participant-summary')).toHaveTextContent('All 3 residents');
  expect(screen.queryByRole('button', { name: 'Mira' })).not.toBeInTheDocument();

  await fireEvent.click(screen.getByRole('button', { name: 'Change' }));
  expect(screen.getByRole('button', { name: 'Mira' })).toHaveAttribute('aria-pressed', 'true');

  await fireEvent.click(screen.getByRole('button', { name: 'Done' }));
  expect(screen.queryByRole('button', { name: 'Mira' })).not.toBeInTheDocument();
});

test('names a partial selection in the collapsed line', () => {
  render(GroupChatAgentPicker, { agents, accountId: 'a', selectedAgentIds: ['m', 'c'] });
  expect(screen.getByTestId('participant-summary')).toHaveTextContent('Mira and Chris');
});

test('counts all available residents as all, leaving paused ones out', () => {
  render(GroupChatAgentPicker, {
    agents: [...agents, { id: 'p', name: 'Sleepy', paused: true }],
    accountId: 'a',
    selectedAgentIds: ['m', 'l', 'c'],
  });
  expect(screen.getByTestId('participant-summary')).toHaveTextContent('All 3 residents');
});

test('opens the full picker when nobody is selected', () => {
  render(GroupChatAgentPicker, { agents, accountId: 'a', selectedAgentIds: [] });
  expect(screen.getByText('Select residents to participate:')).toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Done' })).not.toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Change' })).not.toBeInTheDocument();
});

test('stays open after the first choice from an empty selection', async () => {
  render(GroupChatAgentPicker, { agents, accountId: 'a', selectedAgentIds: [] });
  await fireEvent.click(screen.getByRole('button', { name: 'Mira' }));
  expect(screen.getByRole('button', { name: 'Mira' })).toHaveAttribute('aria-pressed', 'true');
  expect(screen.getByRole('button', { name: 'Lume' })).toBeInTheDocument();
  await fireEvent.click(screen.getByRole('button', { name: 'Done' }));
  expect(screen.getByTestId('participant-summary')).toHaveTextContent('Mira');
});
