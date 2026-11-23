import { render, screen } from '@testing-library/svelte';
import { expect, test } from 'vitest';
import RoomWorkingSpinner from './RoomWorkingSpinner.svelte';

test('shows nothing when nobody is working', () => {
  render(RoomWorkingSpinner, { agents: [] });
  expect(screen.queryByTestId('room-working')).toBeNull();
});

test('nests a ring per resident, newest outermost, and names everyone working', () => {
  render(RoomWorkingSpinner, {
    agents: [
      { id: 'm', name: 'Mira', colour: 'violet' },
      { id: 'l', name: 'Lume', colour: 'orange' },
    ],
  });
  const spinner = screen.getByTestId('room-working');
  expect(spinner.dataset.colour).toBe('violet');
  expect(spinner.getAttribute('title')).toBe('Mira and Lume working');
  const rings = screen.getAllByTestId('room-working-ring');
  expect(rings.map((ring) => ring.dataset.colour)).toEqual(['violet', 'orange']);
  expect(rings[0].className).toContain('text-violet-600');
  expect(rings[1].className).toContain('text-orange-600');
  expect(rings[1].style.inset).toBe('3px');
  expect(spinner.style.width).toBe('18px');
});

test('stops nesting at four rings but still names everyone', () => {
  const names = ['A', 'B', 'C', 'D', 'E'];
  render(RoomWorkingSpinner, { agents: names.map((name) => ({ id: name, name, colour: 'blue' })) });
  expect(screen.getAllByTestId('room-working-ring')).toHaveLength(4);
  expect(screen.getByLabelText('A, B, C, D, and E working')).toBeTruthy();
});

test('falls back to the primary colour for a resident without one', () => {
  render(RoomWorkingSpinner, { agents: [{ id: 'x', name: 'Sol', colour: null }] });
  expect(screen.getByTestId('room-working-ring').className).toContain('text-primary');
  expect(screen.getByLabelText('Sol working')).toBeTruthy();
});

test('distinguishes waking residents from working ones using the same ring', () => {
  const { unmount } = render(RoomWorkingSpinner, {
    agents: [{ id: 'l', name: 'Lume', colour: 'orange', phase: 'waking' }],
  });
  expect(screen.getByLabelText('Lume waking up')).toBeTruthy();
  unmount();

  const { unmount: unmountMixed } = render(RoomWorkingSpinner, {
    agents: [
      { id: 'l', name: 'Lume', colour: 'orange', phase: 'waking' },
      { id: 'm', name: 'Mira', colour: 'violet' },
    ],
  });
  expect(screen.getByLabelText('Lume waking up, Mira working')).toBeTruthy();
  unmountMixed();

  render(RoomWorkingSpinner, {
    agents: [
      { id: 'm', name: 'Mira', colour: 'violet' },
      { id: 'l', name: 'Lume', colour: 'orange', phase: 'waking' },
      { id: 'c', name: 'Claude', colour: 'amber', phase: 'waking' },
    ],
  });
  expect(screen.getByLabelText('Mira working, Lume and Claude waking up')).toBeTruthy();
});
