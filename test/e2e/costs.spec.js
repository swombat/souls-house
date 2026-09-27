import { expect, test } from '@playwright/test';

for (const costs of ['unpriced', 'mixed']) {
  test(`account and resident costs preserve ${costs} usage`, async ({ page, request }, testInfo) => {
    const runId = `costs-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const response = await request.post('/test/e2e/setup', { data: { run_id: runId, costs } });
    expect(response.ok()).toBe(true);
    const setup = await response.json();
    try {
      await page.goto('/login');
      await page.getByLabel(/email/i).fill(setup.primary_user.email);
      await page.getByLabel(/password/i).fill(setup.password);
      await page.getByRole('button', { name: /sign in|log in/i }).click();
      await expect(page).toHaveURL(/\/$/);
      await page.goto(`/accounts/${setup.account_param}/costs`);
      const warning = page.getByRole('region', { name: 'Unestimated usage' });
      await expect(warning).toContainText('E2E Critic');
      await expect(warning).toContainText('future-unpriced-model');
      await expect(warning).toContainText('2 interactions');
      await expect(warning).toContainText('no price is configured');
      if (costs === 'mixed') {
        await expect(page.getByText('≈$61.00').first()).toBeVisible();
        await expect(page.getByText('No estimated interaction costs are available yet.')).toBeHidden();
      } else {
        await expect(page.getByText('No estimated interaction costs are available yet.')).toBeVisible();
        await expect(page.getByText('≈$0.0000')).toBeHidden();
      }
      await page.screenshot({ path: testInfo.outputPath('account-costs.png'), fullPage: true });
      await page.goto(setup.agents[1].edit_url);
      await page.getByRole('button', { name: 'Costs', exact: true }).click();
      await expect(warning).toContainText('future-unpriced-model');
      await expect(warning).toContainText('2 interactions');
      await page.setViewportSize({ width: 390, height: 844 });
      await expect(warning).toBeVisible();
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
      await page.screenshot({ path: testInfo.outputPath('resident-costs-mobile.png'), fullPage: true });
    } finally {
      const cleanup = await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
      expect(cleanup.ok()).toBe(true);
    }
  });
}
