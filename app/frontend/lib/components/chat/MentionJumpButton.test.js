import { tick } from 'svelte';
import { render, screen, fireEvent } from '@testing-library/svelte';
import { beforeEach, expect, test, vi } from 'vitest';
import { page } from '@inertiajs/svelte';
import MentionJumpButton from './MentionJumpButton.svelte';
import { findMentionElement, nextMentionTarget } from '$lib/mention-jump';

vi.mock('@inertiajs/svelte', async () => {
  const { writable } = await import('svelte/store');
  return { page: writable({ props: {} }) };
});

beforeEach(() => {
  page.set({ props: { reply_attention: { messages: ['old', 'mid', 'new'] } } });
});

test('walks newest first, then older, then round to the newest', () => {
  const list = ['old', 'mid', 'new'];
  expect(nextMentionTarget(list, null)).toBe('new');
  expect(nextMentionTarget(list, 'new')).toBe('mid');
  expect(nextMentionTarget(list, 'mid')).toBe('old');
  expect(nextMentionTarget(list, 'old')).toBe('new');
  expect(nextMentionTarget(list, 'dismissed')).toBe('new');
  expect(nextMentionTarget([], null)).toBeNull();
});

test('finds the flag by exact id, not by prefix', () => {
  const root = document.createElement('div');
  root.innerHTML =
    '<button data-reply-attention-target="abc1"></button><button data-reply-attention-target="abc"></button>';
  expect(findMentionElement(root, 'abc')).toBe(root.children[1]);
  expect(findMentionElement(root, 'zzz')).toBeNull();
});

test('no button when nothing in this thread flagged you', () => {
  page.set({ props: { reply_attention: { messages: [] } } });
  render(MentionJumpButton, { chatId: 'chat', reveal: vi.fn() });
  expect(screen.queryByTestId('mention-jump')).not.toBeInTheDocument();
});

test('each tap reveals the next older mention and rings its message', async () => {
  const card = document.createElement('div');
  card.setAttribute('data-message-card', '');
  const flag = document.createElement('button');
  card.appendChild(flag);
  const seen = [];
  const reveal = vi.fn(async (find) => {
    const root = document.createElement('div');
    root.innerHTML = '<span data-reply-attention-target="new"></span><span data-reply-attention-target="mid"></span>';
    seen.push(find(root)?.dataset.replyAttentionTarget);
    return flag;
  });
  render(MentionJumpButton, { chatId: 'chat', reveal });
  const button = screen.getByTestId('mention-jump');
  expect(button).toHaveTextContent('3');
  expect(button).toHaveAccessibleName(/mentioned you \(3\)/);
  await fireEvent.click(button);
  await tick();
  expect(card).toHaveClass('ring-2');
  await fireEvent.click(button);
  await tick();
  expect(seen).toEqual(['new', 'mid']);
});

test('says so when the message cannot be found', async () => {
  render(MentionJumpButton, { chatId: 'chat', reveal: vi.fn(async () => null) });
  await fireEvent.click(screen.getByTestId('mention-jump'));
  await tick();
  expect(screen.getByRole('status')).toHaveTextContent("Couldn't find that message");
});
