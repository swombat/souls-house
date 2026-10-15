import { render, screen } from '@testing-library/svelte';
import { expect, test } from 'vitest';
import RoomWorkingSpinner from './RoomWorkingSpinner.svelte';

test('shows nothing when nobody is working', () => {
  render(RoomWorkingSpinner, { agents: [] });
  expect(screen.queryByTestId('room-working')).toBeNull();
});

test('spins in the newest resident colour and names everyone working', () => {
  render(RoomWorkingSpinner, {
    agents: [
      { id: 'm', name: 'Mira', colour: 'violet' },
      { id: 'l', name: 'Lume', colour: 'orange' },
    ],
  });
  const spinner = screen.getByTestId('room-working');
  expect(spinner.dataset.colour).toBe('violet');
  expect(spinner.className).toContain('text-violet-600');
  expect(spinner.getAttribute('title')).toBe('Mira and Lume working');
});

test('falls back to the primary colour for a resident without one', () => {
  render(RoomWorkingSpinner, { agents: [{ id: 'x', name: 'Sol', colour: null }] });
  expect(screen.getByTestId('room-working').className).toContain('text-primary');
  expect(screen.getByLabelText('Sol working')).toBeTruthy();
});
