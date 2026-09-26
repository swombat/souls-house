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

    test('uploads JSON and unknown formats in new and existing conversations without a picker filter', async ({
      page,
    }) => {
      const composer = page.getByTestId('message-composer');
      const input = composer.locator('input[type=file]');
      await expect(input).not.toHaveAttribute('accept');
      await input.setInputFiles({
        name: 'settings.json',
        mimeType: 'application/json',
        buffer: Buffer.from('{"example":true}'),
      });
      await composer.locator('textarea').fill('JSON attachment');
      await page.getByRole('button', { name: 'Start conversation' }).click();
      await expect(page).toHaveURL(/\/chats\/[^/]+$/);
      await expect(page.getByRole('link', { name: /settings.json/ })).toBeVisible();
      await expect(input).not.toHaveAttribute('accept');
      await input.setInputFiles({
        name: 'custom.unrecognized',
        mimeType: 'application/octet-stream',
        buffer: Buffer.from('synthetic opaque file'),
      });
      await composer.locator('textarea').fill('Unknown format attachment');
      await page.getByRole('button', { name: 'Send message', exact: true }).click();
      const attachment = page.getByRole('link', { name: /custom.unrecognized/ });
      await expect(attachment).toBeVisible();
      await expect(attachment).toHaveAttribute('download', 'custom.unrecognized');
      await page.reload();
      await expect(attachment).toBeVisible();
      await expect(page.getByRole('link', { name: /settings.json/ })).toBeVisible();
    });

    test('names the conversation before sending its first message', async ({ page }) => {
      await page.getByTitle('Edit chat title').click();
      await page.locator('header input[type="text"]').fill('A conversation for Paulina');
      // Blur also saves, so touch users do not need a hardware Enter key.
      await page.getByTestId('message-composer').locator('textarea').click();
      await expect(page.getByTitle('Edit chat title')).toHaveText('A conversation for Paulina');
      await expect(page).toHaveURL(new RegExp(`/accounts/${setup.account_id}/chats$`));
      await page.getByTestId('message-composer').locator('textarea').fill('Hello there');
      await page.getByRole('button', { name: 'Start conversation' }).click();
      await expect(page).toHaveURL(/\/chats\/[^/]+$/);
      await expect(page.getByTitle('Edit chat title')).toHaveText('A conversation for Paulina');
      await page.reload();
      await expect(page.getByTitle('Edit chat title')).toHaveText('A conversation for Paulina');
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
    });

    test('offers the three latest conversations on mobile only', async ({ page }) => {
      for (const title of ['Oldest', 'Third latest', 'Second latest', 'Most recent']) {
        await page.goto(`/accounts/${setup.account_id}/chats`);
        await page.getByTitle('Edit chat title').click();
        await page.locator('header input[type="text"]').fill(title);
        await page.locator('header input[type="text"]').press('Enter');
        await page.getByTestId('message-composer').locator('textarea').fill('A synthetic first message');
        await page.getByRole('button', { name: 'Start conversation' }).click();
        await expect(page).toHaveURL(/\/chats\/[^/]+$/);
      }
      await page.goto(`/accounts/${setup.account_id}/chats`);
      const recent = page.getByRole('navigation', { name: 'Recent conversations' });
      if (width < 768) {
        await expect(recent).toBeVisible();
        await expect(recent.getByRole('link')).toHaveText(['Most recent', 'Second latest', 'Third latest']);
        await recent.getByRole('link', { name: 'Second latest', exact: true }).click();
        await expect(page.getByTitle('Edit chat title')).toHaveText('Second latest');
      } else {
        await expect(recent).toBeHidden();
      }
    });
  });
}
