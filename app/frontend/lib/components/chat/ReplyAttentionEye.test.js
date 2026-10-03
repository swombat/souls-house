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

test('message tag dismisses exactly its own flag, not the thread cutoff', async () => {
  page.set({ props: { reply_attention: { messages: ['ask'], through_messages: { chat: 'newer' } } } });
  render(ReplyAttentionEye, { chatId: 'chat', accountId: 'account', messageId: 'ask' });
  const tag = screen.getByRole('button', { name: /This message appears to have flagged you/ });
  expect(tag).toHaveTextContent('Flagged you');
  await fireEvent.click(tag);
  expect(router.post).toHaveBeenCalledWith(
    '/accounts/account/chats/chat/reply_dismissal',
    { message_id: 'ask' },
    expect.any(Object)
  );
});

test('message tag first tap explains and second dismisses only that message', async () => {
  page.set({ props: { reply_attention: { messages: ['ask'] } } });
  render(ReplyAttentionEye, { chatId: 'chat', accountId: 'account', messageId: 'ask' });
  const tag = screen.getByRole('button', { name: /This message appears/ });
  const tap = async () => {
    await fireEvent(tag, Object.assign(new Event('pointerdown', { bubbles: true }), { pointerType: 'touch' }));
    await fireEvent.click(tag);
  };
  await tap();
  expect(router.post).not.toHaveBeenCalled();
  expect(screen.getByText(/Tap again to dismiss this flag/)).toBeVisible();
  await fireEvent.click(document.body);
  expect(screen.queryByText(/Tap again to dismiss this flag/)).not.toBeInTheDocument();
  await tap();
  expect(router.post).not.toHaveBeenCalled();
  await tap();
  expect(router.post.mock.calls[0][1]).toEqual({ message_id: 'ask' });
  page.set({ props: { reply_attention: { messages: [] } } });
  await tick();
  expect(screen.queryByRole('button')).not.toBeInTheDocument();
});

test('does not tag another message even when the thread is flagged', () => {
  render(ReplyAttentionEye, { chatId: 'chat', accountId: 'account', messageId: 'unflagged' });
  expect(screen.queryByRole('button')).not.toBeInTheDocument();
});

test('touch first explains, then dismisses; a new request resets confirmation', async () => {
  render(ReplyAttentionEye, { chatId: 'chat', accountId: 'account' });
  const eye = screen.getByRole('button', { name: /You have a mention or request/ });
  const tap = async () => {
    await fireEvent(eye, Object.assign(new Event('pointerdown', { bubbles: true }), { pointerType: 'touch' }));
    await fireEvent.click(eye);
  };
  await tap();
  expect(router.post).not.toHaveBeenCalled();
  expect(screen.getByText(/Tap again to dismiss the notification/)).toBeVisible();
  page.set({ props: { reply_attention: { chats: { chat: 3 }, through_messages: { chat: 'new-message' } } } });
  await tick();
  await tap();
  expect(router.post).not.toHaveBeenCalled();
  await tap();
  expect(router.post).toHaveBeenCalledWith(
    '/accounts/account/chats/chat/reply_dismissal',
    { through_message_id: 'new-message' },
    expect.any(Object)
  );
});
