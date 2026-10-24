import { test, expect } from '@playwright/test';

// The public decisions pages, logged out: home → footer → index → entry → back.
test.describe('decisions pages', () => {
  for (const [name, viewport] of [
    ['desktop', { width: 1440, height: 900 }],
    ['mobile', { width: 390, height: 844 }],
  ]) {
    test(`a visitor can read a decision and come back on ${name}`, async ({ page }, testInfo) => {
      await page.setViewportSize(viewport);
      await page.goto('/');
      await page.getByRole('contentinfo').getByRole('link', { name: 'Decisions' }).click();

      await expect(page).toHaveURL(/\/decisions$/);
      await expect(page.getByRole('heading', { level: 1, name: 'Why the house is the way it is' })).toBeVisible();
      const entry = page.getByRole('link', { name: /Which models a subsidised resident can start on/ });
      await expect(entry).toBeVisible();
      await expect(entry.getByText('Decided')).toBeVisible();
      await page.screenshot({ path: testInfo.outputPath(`decisions-index-${name}.png`), fullPage: true });

      await entry.click();
      await expect(page).toHaveURL(/\/decisions\/free-resident-model$/);
      await expect(page.getByRole('heading', { level: 1, name: 'Which models a subsidised resident can start on' })).toBeVisible();
      await expect(page.getByRole('heading', { name: 'What we decided' })).toBeVisible();
      await expect(page.getByRole('table').first()).toBeVisible();
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
      expect(overflow).toBeLessThanOrEqual(0);
      await page.screenshot({ path: testInfo.outputPath(`decisions-entry-${name}.png`), fullPage: true });

      await page.getByRole('main').getByRole('link', { name: 'Why the house is the way it is' }).click();
      await expect(page).toHaveURL(/\/decisions$/);
      await page.goBack();
      await expect(page).toHaveURL(/\/decisions\/free-resident-model$/);
    });
  }
});
