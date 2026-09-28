import { render, screen } from '@testing-library/svelte';
import { expect, test } from 'vitest';
import ChatMessageList from './ChatMessageList.svelte';

const messages = [
  { id: 1, role: 'user', content: 'Before completion', created_at: '2026-09-27T10:02:00Z' },
  { id: 2, role: 'user', content: 'After completion', created_at: '2026-09-27T10:05:00Z' },
];
const run = {
  id: 'a',
  run_id: 'run-a',
  agent_name: 'Resident',
  active: true,
  status_label: 'is working',
  created_at: '2026-09-26T10:00:00Z',
  events: [],
};
const precedes = (a, b) => Boolean(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING);

test('active cards stay below speech, then move and collapse on completion without being recreated', async () => {
  const { container, rerender } = render(ChatMessageList, {
    allMessages: messages,
    visibleMessages: messages,
    runtimeInteractions: [run],
  });
  const card = screen.getByTestId('runtime-activity-card');
  expect(precedes(screen.getByText('After completion'), card)).toBe(true);
  expect(card.querySelector('details').open).toBe(true);
  // An active run from yesterday must not insert a backwards date divider.
  expect(container.querySelectorAll('.rounded-full.text-xs')).toHaveLength(1);

  await rerender({
    allMessages: messages,
    visibleMessages: messages,
    runtimeInteractions: [{ ...run, active: false, finished_at: '2026-09-27T10:03:00Z', status_label: 'finished' }],
  });
  expect(screen.getByTestId('runtime-activity-card')).toBe(card);
  expect(precedes(screen.getByText('Before completion'), card)).toBe(true);
  expect(precedes(card, screen.getByText('After completion'))).toBe(true);
  expect(card.querySelector('details').open).toBe(false);
});

test('ordinary linked messages group without a flag and keep active work below the entire group', () => {
  const linked = [1, 2].map((id) => ({
    id: `linked-${id}`,
    role: 'assistant',
    agent_id: 9,
    runtime_interaction_id: 55,
    content: `Ordinary update ${id}`,
    created_at: `2026-09-28T08:0${id}:00Z`,
  }));
  const { container } = render(ChatMessageList, {
    allMessages: linked,
    visibleMessages: linked,
    runtimeInteractions: [{ ...run, id: 'group-run' }],
  });
  expect(container.querySelectorAll('[data-testid="message-group"]')).toHaveLength(1);
  const sections = container.querySelectorAll('[data-progress-section]');
  expect(sections).toHaveLength(2);
  expect(container.textContent).toContain('1m 00s elapsed');
  expect(precedes(sections[1], container.querySelector('[data-testid="runtime-activity-card"]'))).toBe(true);
});
