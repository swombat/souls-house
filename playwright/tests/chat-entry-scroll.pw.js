import { test, expect } from '@playwright/experimental-ct-svelte';
import Harness from '../ChatEntryHarness.svelte';

test('long conversation opens at bottom without fetching history; resize follows only until reader intent', async ({
  mount,
  page,
}) => {
  const historyRequests = [];
  await page.route('**/*before_id*', (route) => {
    historyRequests.push(route.request().url());
    return route.fulfill({ json: { messages: [], has_more: false } });
  });
  const component = await mount(Harness);
  const history = page.getByTestId('chat-messages');
  const atBottom = () => history.evaluate((el) => Math.abs(el.scrollHeight - el.clientHeight - el.scrollTop) < 2);
  await expect.poll(atBottom).toBe(true);
  expect(historyRequests).toEqual([]);
  await component.update({ props: { id: 'first', count: 31 } });
  await expect.poll(atBottom).toBe(true);
  await page.locator('[data-chat-content]').evaluate((el) => (el.style.paddingBottom = '1000px'));
  await expect.poll(atBottom).toBe(true);
  await history.dispatchEvent('wheel');
  await history.evaluate((el) => el.scrollTo({ top: 1200, behavior: 'instant' }));
  await page.locator('[data-chat-content]').evaluate((el) => (el.style.paddingBottom = '1500px'));
  await expect.poll(() => history.evaluate((el) => el.scrollTop)).toBe(1200);
  await component.update({ props: { id: 'first', count: 101 } });
  await expect.poll(() => history.evaluate((el) => el.scrollTop)).toBe(1200);
  await component.update({ props: { id: 'second', count: 120 } });
  await expect.poll(atBottom).toBe(true);
  expect(historyRequests).toEqual([]);
  // Genuine scrolling into history still loads older messages.
  await history.dispatchEvent('wheel');
  await history.evaluate((el) => el.scrollTo({ top: 0, behavior: 'instant' }));
  await expect.poll(() => historyRequests.length).toBe(1);
});
