import { test, expect } from '@playwright/experimental-ct-svelte';
import Harness from '../MentionJumpHarness.svelte';

const message = (n) => ({ id: `m${n}`, content: `Message ${n}`, role: 'user', created_at: '2026-10-01T07:00:00Z' });
const range = (from, to) => Array.from({ length: to - from }, (_, i) => message(from + i));

test('walks newest to an older mention two pages back, scrolls to it, and rings only the last', async ({
  mount,
  page,
}) => {
  const requests = [];
  await page.route('**/*before_id*', (route) => {
    const before = new URL(route.request().url()).searchParams.get('before_id');
    requests.push(before);
    if (before === 'm30') return route.fulfill({ json: { messages: range(10, 30), has_more: true, oldest_id: 'm10' } });
    return route.fulfill({ json: { messages: range(0, 10), has_more: false, oldest_id: 'm0' } });
  });
  await mount(Harness, { props: { flagged: ['m3', 'm45'] } });
  const jump = page.getByTestId('mention-jump');
  const card = (id) =>
    page.locator(`[data-reply-attention-target="${id}"]`).locator('xpath=ancestor::*[@data-message-card][1]');

  await jump.click();
  await expect(card('m45')).toHaveClass(/ring-2/);
  expect(requests).toEqual([]);

  // Second tap, well inside the first ring's two seconds: m3 is two pages back.
  await jump.click();
  await expect(card('m3')).toHaveClass(/ring-2/);
  await expect(card('m45')).not.toHaveClass(/ring-2/);
  expect(requests).toEqual(['m30', 'm10']);
  await expect(page.locator('[data-reply-attention-target="m3"]')).toBeInViewport();

  // And the ring comes off by itself.
  await expect(card('m3')).not.toHaveClass(/ring-2/, { timeout: 4000 });
});

test('a failed history page ends the walk after one request', async ({ mount, page }) => {
  let requests = 0;
  await page.route('**/*before_id*', (route) => {
    requests += 1;
    return route.fulfill({ status: 500, body: 'nope' });
  });
  await mount(Harness, { props: { flagged: ['m3'] } });
  await page.getByTestId('mention-jump').click();
  await expect(page.getByRole('status')).toHaveText(/Couldn't find that message/);
  expect(requests).toBe(1);
});
