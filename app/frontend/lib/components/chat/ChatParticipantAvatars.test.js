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

test('the working ring is the resident’s own colour, as in the rooms spinner', () => {
  const { container } = render(ChatParticipantAvatars, {
    participants: [
      { id: 'lume', type: 'agent', name: 'Lume', colour: 'orange' },
      { id: 'mira', type: 'agent', name: 'Mira', colour: 'violet' },
    ],
    workingAgentIds: ['lume'],
  });
  const ring = container.querySelector('.working-ring');
  expect(ring.dataset.colour).toBe('orange');
  expect(ring).toHaveClass('text-orange-600');
  expect(ring).not.toHaveClass('text-primary');
});

test('a resident without a colour keeps the primary ring', () => {
  const { container } = render(ChatParticipantAvatars, { participants, workingAgentIds: ['mira'] });
  expect(container.querySelector('.working-ring')).toHaveClass('text-primary');
});
