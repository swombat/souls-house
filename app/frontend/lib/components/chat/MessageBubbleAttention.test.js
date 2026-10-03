import { render, screen } from '@testing-library/svelte';
import { expect, test, vi } from 'vitest';
import { page } from '@inertiajs/svelte';
import MessageBubble from './MessageBubble.svelte';

vi.mock('@inertiajs/svelte', async () => {
  const { writable } = await import('svelte/store');
  return { page: writable({ props: {} }), router: { post: vi.fn() } };
});

test('a human message can show its own personal flag', () => {
  page.set({ props: { reply_attention: { messages: ['human'] } } });
  render(MessageBubble, {
    accountId: 'account',
    chatId: 'chat',
    message: { id: 'human', role: 'user', content: 'Please look.', created_at: '2026-10-03T12:00:00Z' },
  });
  expect(screen.getByRole('button', { name: /This message appears/ })).toHaveTextContent('Flagged you');
});

test('grouped resident updates keep the tag on the source section', () => {
  page.set({ props: { reply_attention: { messages: ['second'] } } });
  const first = { id: 'first', role: 'assistant', content: 'An update.', created_at: '2026-10-03T12:00:00Z' };
  const second = { ...first, id: 'second', content: 'Please reply.' };
  const { container } = render(MessageBubble, {
    accountId: 'account',
    chatId: 'chat',
    message: first,
    progressMessages: [first, second],
  });
  const tag = screen.getByRole('button', { name: /This message appears/ });
  expect(tag.closest('section')).toHaveAttribute('data-progress-section', 'second');
  expect(container.querySelector('[data-progress-section="first"]')).not.toHaveTextContent('Flagged you');
});
