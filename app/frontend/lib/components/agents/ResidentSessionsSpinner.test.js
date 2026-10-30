import { render, screen } from '@testing-library/svelte';
import ResidentSessionsSpinner from './ResidentSessionsSpinner.svelte';

test('shows nothing when no session is running', () => {
  render(ResidentSessionsSpinner, { sessions: { chat: 0, telegram: 0, other: 0 } });
  expect(screen.queryByTestId('resident-sessions')).not.toBeInTheDocument();
  render(ResidentSessionsSpinner, { sessions: undefined });
  expect(screen.queryByTestId('resident-sessions')).not.toBeInTheDocument();
});

test('shows the total and one nested ring per running kind, chat outermost', () => {
  render(ResidentSessionsSpinner, { sessions: { chat: 2, telegram: 0, other: 1 } });
  const badge = screen.getByTestId('resident-sessions');
  expect(badge).toHaveTextContent('3');
  const rings = screen.getAllByTestId('resident-sessions-ring');
  expect(rings.map((ring) => ring.dataset.kind)).toEqual(['chat', 'other']);
  expect(rings[0].style.inset).toBe('0px');
  expect(rings[1].style.inset).toBe('3px');
  expect(screen.getByRole('img')).toHaveAccessibleName('3 active sessions: 2 chat · 1 other');
});

test('all three kinds nest chat, Telegram, other', () => {
  render(ResidentSessionsSpinner, { sessions: { chat: 1, telegram: 1, other: 1 } });
  expect(screen.getAllByTestId('resident-sessions-ring').map((ring) => ring.dataset.kind)).toEqual([
    'chat',
    'telegram',
    'other',
  ]);
});

test('a single session reads in the singular', () => {
  render(ResidentSessionsSpinner, { sessions: { chat: 0, telegram: 1, other: 0 } });
  expect(screen.getByRole('img')).toHaveAccessibleName('1 active session: 1 Telegram');
});
