import { render, screen } from '@testing-library/svelte';
import { test, expect } from 'vitest';
import ChatParticipantAvatars from './ChatParticipantAvatars.svelte';

const participants = [
  { id: 'mira', type: 'agent', name: 'Mira', icon: 'eye' },
  { id: 'peer', type: 'agent', name: 'Peer' },
  { type: 'human', name: 'Daniel' },
];

test('only working residents get a ring, which clears on a live prop update', async () => {
  const { container, rerender } = render(ChatParticipantAvatars, { participants, workingAgentIds: ['mira'] });
  expect(screen.getByRole('img', { name: 'Mira is working' })).toHaveClass('working');
  expect(screen.getByRole('img', { name: 'Peer' })).not.toHaveClass('working');
  expect(container.querySelectorAll('.working-ring')).toHaveLength(1);
  await rerender({ participants, workingAgentIds: [] });
  expect(screen.getByRole('img', { name: 'Mira' })).not.toHaveClass('working');
  expect(container.querySelectorAll('.working-ring')).toHaveLength(0);
});

test('a working resident is not hidden behind the participant overflow', () => {
  const humans = Array.from({ length: 8 }, (_, i) => ({ type: 'human', name: `Human ${i}` }));
  render(ChatParticipantAvatars, { participants: [...humans, participants[0]], workingAgentIds: ['mira'] });
  expect(screen.getByRole('img', { name: 'Mira is working' })).toBeInTheDocument();
  expect(screen.getByTitle('2 more participants')).toBeInTheDocument();
});
