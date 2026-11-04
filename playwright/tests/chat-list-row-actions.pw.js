import { test, expect } from '@playwright/experimental-ct-svelte';
import ChatListItemsHarness from '../ChatListItemsHarness.svelte';

const rooms = [{ id: 'devRm', name: 'Dev' }];
const chats = [
  { id: 'c1', title: 'Build: stalled-thread sweeper — June follow-up and more', message_count: 225 },
  { id: 'c2', title: 'Song attribution confusion', message_count: 20, room_id: 'devRm' },
  { id: 'c3', title: 'Live expired-login count through the account switcher', message_count: 26 },
].map((chat) => ({ manual_responses: false, visual_tag: null, room_id: null, ...chat }));

test('on desktop, hovering a card shows the actions button above the count, clear of the title', async ({
  mount,
  page,
}) => {
  await page.setViewportSize({ width: 1280, height: 600 });
  const component = await mount(ChatListItemsHarness, { props: { chats, rooms, waiting: { c3: 1 } } });
  const first = component.locator('[data-row-actions]').first();
  await expect(first).toHaveCSS('opacity', '0');
  await page.screenshot({ path: 'tmp/row-actions-rest.png' });

  await component.getByRole('link', { name: /stalled-thread/ }).hover();
  await expect(first).toHaveCSS('opacity', '1');
  const button = first.getByRole('button', { name: /^Actions for / });
  const title = component.getByText(/stalled-thread/);
  const [b, t] = [await button.boundingBox(), await title.boundingBox()];
  expect(t.x + t.width).toBeLessThanOrEqual(b.x);
  await page.screenshot({ path: 'tmp/row-actions-hover.png' });

  // With the reply-attention eye there too, the title still clears both.
  await component.getByRole('link', { name: /expired-login/ }).hover();
  const third = component.locator('[data-row-actions]').nth(2).getByRole('button');
  const t3 = await component.getByText(/expired-login/).boundingBox();
  expect(t3.x + t3.width).toBeLessThanOrEqual((await third.boundingBox()).x);
  await page.screenshot({ path: 'tmp/row-actions-hover-eye.png' });

  let sent = null;
  await page.route('**/accounts/acc/chats/c1/room', (route) => {
    sent = route.request().postDataJSON();
    route.fulfill({ status: 204, body: '' });
  });
  await component.getByRole('link', { name: /stalled-thread/ }).hover();
  await button.click();
  await expect(page.getByRole('menuitem', { name: 'Main' })).toHaveAttribute('data-disabled');
  await page.screenshot({ path: 'tmp/row-actions-menu.png' });
  await page.getByRole('menuitem', { name: 'Dev' }).click();
  await expect.poll(() => sent).toEqual({ room_id: 'devRm' });
});

test('with no other room the menu still offers Archive, without rooms', async ({ mount, page }) => {
  await page.setViewportSize({ width: 1280, height: 600 });
  const component = await mount(ChatListItemsHarness, { props: { chats, rooms: [] } });
  await expect(component.locator('[data-row-actions]')).toHaveCount(3);
  let archived = false;
  await page.route('**/accounts/acc/chats/c1/archive', (route) => {
    archived = route.request().method() === 'POST';
    route.fulfill({ status: 204, body: '' });
  });
  await component.getByRole('link', { name: /stalled-thread/ }).hover();
  await component.locator('[data-row-actions]').first().getByRole('button').click();
  await expect(page.getByRole('menuitem', { name: 'Archive' })).toBeVisible();
  await expect(page.getByText('Move to room')).toHaveCount(0);
  await page.screenshot({ path: 'tmp/row-actions-menu-no-rooms.png' });
  await page.getByRole('menuitem', { name: 'Archive' }).click();
  await expect.poll(() => archived).toBe(true);
});

test.describe('touch', () => {
  test.use({ hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } });

  test('on a phone the button is not shown', async ({ mount }) => {
    const component = await mount(ChatListItemsHarness, { props: { chats, rooms } });
    await expect(component.getByRole('button', { name: /^Actions for / })).toBeHidden();
  });
});
