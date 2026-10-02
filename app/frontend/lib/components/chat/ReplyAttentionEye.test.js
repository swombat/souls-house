import { tick } from 'svelte';
import { render, screen, fireEvent } from '@testing-library/svelte';
import { beforeEach, expect, test, vi } from 'vitest';
import { page, router } from '@inertiajs/svelte';
import ReplyAttentionEye from './ReplyAttentionEye.svelte';

vi.mock('@inertiajs/svelte', async () => {
  const { writable } = await import('svelte/store');
  return { page: writable({ props: {} }), router: { post: vi.fn() } };
});

beforeEach(() => {
  page.set({ props: { reply_attention: { chats: { chat: 2 }, through_messages: { chat: 'visible-message' } } } });
});

test('explains mentions and both dismissal routes, posting only the rendered cutoff', async () => {
  render(ReplyAttentionEye, { chatId: 'chat', accountId: 'account' });
  const eye = screen.getByRole('button', { name: /You have a mention or request/ });
  expect(eye).toHaveAttribute(
    'title',
    expect.stringMatching(/Click to dismiss.*Responding to the thread also dismisses/)
  );
  await fireEvent.click(eye);
  expect(router.post).toHaveBeenCalledWith(
    '/accounts/account/chats/chat/reply_dismissal',
    { through_message_id: 'visible-message' },
    expect.objectContaining({ preserveScroll: true, preserveState: true })
  );
  expect(eye).toBeDisabled();
  router.post.mock.calls[0][2].onFinish();
  await tick();
  expect(eye).not.toBeDisabled();
});

test('does not show a button for unflagged threads', () => {
  render(ReplyAttentionEye, { chatId: 'other', accountId: 'account' });
  expect(screen.queryByRole('button')).not.toBeInTheDocument();
});
