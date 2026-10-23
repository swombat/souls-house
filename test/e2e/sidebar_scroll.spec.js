import { expect, test } from '@playwright/test';

test('clicking a conversation far down the sidebar keeps the list where it was', async ({ page, request }) => {
  await page.setViewportSize({ width: 1280, height: 700 });
  const response = await request.post('/test/e2e/setup', {
    data: { run_id: `sidebar-scroll-${Date.now()}-${Math.random().toString(36).slice(2)}` },
  });
  const setup = await response.json();
  try {
    const chats = [];
    for (let i = 0; i < 30; i++) {
      const fixture = await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 1, seconds_ago: 60 * (i + 1) },
      });
      chats.push((await fixture.json()).chat_id);
    }
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(`/accounts/${setup.account_param}/chats/${chats[0]}`);

    const scroller = page.locator('[data-chat-sidebar-scroller]');
    await expect(scroller.locator(`a[href$="/chats/${chats[25]}"]`)).toBeAttached();
    await scroller.evaluate((el) => el.scrollTo(0, el.scrollHeight));
    const before = await scroller.evaluate((el) => el.scrollTop);
    expect(before).toBeGreaterThan(200);

    const target = scroller.locator(`a[href$="/chats/${chats[25]}"]`);
    await target.click();
    await expect(page).toHaveURL(new RegExp(`/chats/${chats[25]}`));
    await expect(target).toHaveAttribute('aria-current', 'page');
    await expect.poll(() => scroller.evaluate((el) => el.scrollTop)).toBe(before);
    await expect(target).toBeInViewport();
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});
