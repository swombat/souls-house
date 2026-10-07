import { expect, test } from '@playwright/test';

test('resident buttons remain mounted and stationary during background refreshes', async ({ page, request }) => {
  const runId = `resident-bar-${Date.now()}`;
  const setupResponse = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  const setup = await setupResponse.json();
  try {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    const fixtureResponse = await request.post('/test/e2e/conversation_fixture', {
      data: { account_id: setup.account_id, count: 2 },
    });
    const fixture = await fixtureResponse.json();
    await page.goto(`/accounts/${setup.account_id}/chats/${fixture.chat_id}`);
    const button = page.getByRole('button', { name: 'E2E Researcher', exact: true });
    await expect(button).toBeVisible();
    await button.evaluate((node) => {
      const initial = node.getBoundingClientRect();
      window.barChanges = [];
      window.barButton = node;
      window.barFrame = () => {
        const rect = node.getBoundingClientRect();
        if (!node.isConnected || ['x', 'y', 'width', 'height'].some((key) => Math.abs(rect[key] - initial[key]) > 1)) {
          window.barChanges.push({ connected: node.isConnected, rect: rect.toJSON() });
        }
        window.barRaf = requestAnimationFrame(window.barFrame);
      };
      window.barRaf = requestAnimationFrame(window.barFrame);
    });
    for (let i = 0; i < 3; i++) {
      const prefix = `Refresh ${i}`;
      const response = await request.post('/test/e2e/append_messages', {
        data: { chat_id: fixture.chat_id, count: 1, prefix },
      });
      expect(response.ok()).toBe(true);
      await expect(page.getByText(`${prefix} 000`, { exact: true })).toBeVisible();
    }
    expect(await page.evaluate(() => window.barChanges)).toEqual([]);
    expect(await button.evaluate((node) => node === window.barButton)).toBe(true);
  } finally {
    await page.evaluate(() => cancelAnimationFrame(window.barRaf)).catch(() => {});
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
