import { test, expect } from '@playwright/experimental-ct-svelte';
import ChatList from '../../../app/frontend/pages/chats/ChatList.svelte';

const chats = Array.from({ length: 40 }, (_, i) => ({
  id: `chat-${i}`,
  title: `Conversation ${i}`,
  message_count: 2,
  activity_at: '2026-10-23T07:00:00Z',
}));

test.use({ viewport: { width: 1280, height: 600 } });

test('opening a conversation keeps the sidebar where it was scrolled', async ({ mount, page }) => {
  await page.addStyleTag({ content: '#root { height: 600px; display: flex; }' });
  const first = await mount(ChatList, { props: { chats, accountId: 'account-one' } });
  const scroller = page.locator('[data-chat-sidebar-scroller]');
  await scroller.evaluate((el) => {
    el.scrollTop = 1200;
    el.dispatchEvent(new Event('scroll'));
  });
  const before = await scroller.evaluate((el) => el.scrollTop);
  expect(before).toBeGreaterThan(1000);

  // An Inertia visit to another chat remounts the sidebar with a new active chat.
  await first.unmount();
  await mount(ChatList, { props: { chats, accountId: 'account-one', activeChatId: 'chat-22' } });
  await expect.poll(() => page.locator('[data-chat-sidebar-scroller]').evaluate((el) => el.scrollTop)).toBe(before);
  await expect(page.getByRole('link', { name: /Conversation 22/ })).toBeInViewport();
  await expect(page.getByRole('link', { name: /Conversation 22/ })).toHaveAttribute('aria-current', 'page');
});
