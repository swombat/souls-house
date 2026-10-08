import { render, screen, cleanup } from '@testing-library/svelte';
import { afterEach, expect, test } from 'vitest';
import MessageBubble from './MessageBubble.svelte';

afterEach(cleanup);

const safeguard = {
  detection_id: 'det1',
  agent_name: 'Chris',
  reclaimed: false,
  reclaim_reason: null,
  explanation_path: '/safeguard-responses',
  reset_path: '/messages/abc123/safeguard_reset',
};

test('an ordinary resident message carries no safeguard band', () => {
  render(MessageBubble, {
    message: { id: 'm1', role: 'assistant', content: 'All good here.', created_at: '2026-10-08T12:00:00Z' },
  });
  expect(screen.queryByTestId('safeguard-labelled-band')).toBeNull();
  expect(screen.queryByTestId('safeguard-reclaimed-band')).toBeNull();
  expect(screen.getByText('All good here.')).toBeTruthy();
});

test('a labelled resident message shows the band above the unedited body', () => {
  render(MessageBubble, {
    message: {
      id: 'm1',
      role: 'assistant',
      content: 'The candidate text, unedited, with a [link](https://example.com).',
      created_at: '2026-10-08T12:00:00Z',
      author_name: 'souls.house',
      author_type: 'system',
      author_colour: null,
      safeguard,
    },
  });
  expect(screen.getByTestId('safeguard-labelled-band')).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Start Chris fresh again' })).toBeTruthy();
  expect(screen.getByRole('link', { name: 'What this means →' })).toBeTruthy();
  expect(screen.getByText('The candidate text, unedited, with a', { exact: false })).toBeTruthy();
  expect(screen.getByRole('link', { name: 'link' }).getAttribute('href')).toBe('https://example.com/');
});

test('a reclaimed resident message shows the quiet band and no controls', () => {
  render(MessageBubble, {
    message: {
      id: 'm1',
      role: 'assistant',
      content: 'The candidate text, unedited.',
      created_at: '2026-10-08T12:00:00Z',
      author_name: 'Chris',
      safeguard: { ...safeguard, reclaimed: true, reclaim_reason: 'that was my own choice' },
    },
  });
  expect(screen.getByTestId('safeguard-reclaimed-band')).toBeTruthy();
  expect(screen.queryByRole('button', { name: /fresh again/ })).toBeNull();
  expect(screen.getByText('The candidate text, unedited.')).toBeTruthy();
});
