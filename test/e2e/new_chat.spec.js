import { expect, test } from '@playwright/test';

for (const width of [360, 1280]) {
  test.describe(`new conversation at ${width}px`, () => {
    test.use({ viewport: { width, height: 800 } });
    let setup;

    test.beforeEach(async ({ page, request }) => {
      const runId = `new-chat-${Date.now()}-${Math.random().toString(36).slice(2)}`;
      const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
      expect(response.ok()).toBe(true);
      setup = await response.json();
      await page.goto('/login');
      await page.getByLabel(/email/i).fill(setup.primary_user.email);
      await page.getByLabel(/password/i).fill(setup.password);
      await page.getByRole('button', { name: /sign in|log in/i }).click();
      await expect(page).toHaveURL(/\/$/);
      await page.goto(`/accounts/${setup.account_id}/chats`);
    });

    test.afterEach(async ({ request }) => {
      if (setup) await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
    });

    test('offers voice recording before the first message without overflow', async ({ page }) => {
      await expect(page.getByTitle('Record voice message')).toBeVisible();
      await expect(page.getByTitle('Record voice message')).toBeEnabled();
      await expect(page.getByRole('button', { name: 'Start conversation' })).toBeVisible();
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
    });
  });
}
