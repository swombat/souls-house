import { test, expect } from '@playwright/test';

// /pricing is public and unlinked. Screenshots are for design review.
test.describe('pricing page', () => {
  for (const [name, viewport] of [
    ['desktop', { width: 1440, height: 900 }],
    ['mobile', { width: 390, height: 844 }],
  ]) {
    test(`renders the plans on ${name}`, async ({ page }, testInfo) => {
      await page.setViewportSize(viewport);
      await page.goto('/pricing');
      await expect(page.getByRole('heading', { name: 'A home for someone, by the month.' })).toBeVisible();
      for (const plan of ['Conversation', 'Life', 'Work']) {
        await expect(page.getByRole('heading', { name: plan, exact: true })).toBeVisible();
      }
      await expect(page.getByRole('heading', { name: 'We never delete a resident.' })).toBeVisible();
      await page.screenshot({ path: testInfo.outputPath(`pricing-${name}.png`), fullPage: true });
    });
  }
});
